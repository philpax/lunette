-- Provides the UI toolkit host: panels with mount points, element kinds and visuals, layout, routing, and drawing.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local focusContract = require '@lunette-contracts/focus'
local keys = require '@lunette-contracts/keys'
local vocabulary = require '@lunette-contracts/vocabulary'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local config = require '@self/config'
local records = require '@self/private/records'
local registry = require '@self/private/registry'
local themes = require '@self/private/theme'
local tree = require '@self/private/tree'
local layout = require '@self/private/layout'
local input = require '@self/private/input'
local touch = require '@self/private/touch'
local overlay = require '@self/private/overlay'
local presentation = require '@self/private/presentation'
local traversal = require '@self/private/traversal'
local panels = require '@self/private/panel'
local fonts = require '@self/private/rendering/fonts'
local pack = require '@self/private/rendering/pack'
local renderer = require '@self/private/rendering/renderer'

export type Config = config.Config
export type Settings = config.Settings

type Live = {
  record: records.Panel,
  surface: vocabulary.Surface,
  packed: pack.Packed?,
}

local function build(context: plugin.Context, settings: Settings): uiHost.Service
  local frameService = context:require(frame.capability)
  local surfaceService = context:require(surfaces.capability)
  local focusService = context:require(focusContract.capability)
  local traverse: traversal.Traversal
  local mode: themes.Mode = settings.mode
  local accent: uiHost.Color = settings.accent or themes.DEFAULT_ACCENT
  local current = themes.resolve(mode, accent)
  local kinds = registry.new(context)
  local faces = fonts.new()
  local router = input.new()
  local touching = touch.new()
  local live: { Live } = {}
  local recordsOf: { [uiHost.Panel]: records.Panel } = setmetatable({}, { __mode = 'k' }) :: any
  local reportedMissing: { [string]: boolean } = {}
  local resources: renderer.Resources? = nil
  local releaseResources: (() -> ())? = nil

  local env: records.Environment
  local provider: panels.Provider
  env = {
    kind = function(name: string): records.Kind
      local kind = registry.kind(kinds, name)
      if kind == kinds.missing and not reportedMissing[name] then
        reportedMissing[name] = true
        protected.call('ui: element kinds', function(): ()
          error(`the kind {name} is not registered`, 0)
        end)
      end
      return kind
    end,
    theme = function(): uiHost.Theme
      return current
    end,
    protect = protected.call,
    removed = function(_panel: records.Panel, node: records.Node): ()
      input.removed(router, node)
    end,
    dispatch = function(node: records.Node, event: uiHost.Event): boolean
      return input.dispatch(env, node, event)
    end,
    portal = function(_panel: records.Panel, node: records.Node): ()
      overlay.render(provider, node)
    end,
    unportal = function(node: records.Node): ()
      overlay.close(provider, node)
    end,
    -- A press outside an overlay's chain asks the portal to close through its onDismiss callback.
    blocked = function(target: records.Panel): boolean
      local panels: { records.Panel } = {}
      for _, entry in live do
        panels[#panels + 1] = entry.record
      end
      return presentation.blocked(target, panels)
    end,
    focusNode = function(node: records.Node, visible: boolean): boolean
      return traversal.focusNode(traverse, node, visible)
    end,
    blurNode = function(node: records.Node): ()
      traversal.blurNode(traverse, node)
    end,
    pressed = function(pressedPanel: records.Panel, node: records.Node?): ()
      for _, entry in table.clone(live) do
        local relation = entry.record.overlay
        if relation and not entry.record.dead and not overlay.contains(entry.record, pressedPanel, node) then
          relation.portal.handle:emit 'onDismiss'
        end
      end
    end,
  }

  provider = {
    env = env,
    router = router,
    offer = function(record: records.Panel, surface: vocabulary.Surface): ()
      table.insert(live, { record = record, surface = surface })
    end,
    resolve = function(handle: uiHost.Panel): records.Panel
      return assert(recordsOf[handle], 'ui: the panel was not made by this host')
    end,
    release = function(record: records.Panel): ()
      traversal.release(record)
      for index, entry in live do
        if entry.record == record then
          table.remove(live, index)
          break
        end
      end
    end,
  }

  traverse = traversal.new(context, focusService, env, function(): { records.Panel }
    local list: { records.Panel } = {}
    for _, entry in live do
      list[#list + 1] = entry.record
    end
    return list
  end)

  surfaceService:offer(context, {
    name = 'ui-host',
    list = function(): { vocabulary.Surface }
      local list: { vocabulary.Surface } = {}
      for _, entry in live do
        local relation = entry.record.overlay
        if entry.record.visible and entry.record.width > 0 and (relation == nil or relation.hit) then
          list[#list + 1] = entry.surface
        end
      end
      return list
    end,
  })

  context:effect(function(): () -> ()
    return function(): ()
      for _, entry in table.clone(live) do
        panels.destroy(provider, entry.record)
      end
      if releaseResources then
        releaseResources()
        releaseResources, resources = nil, nil
      end
      fonts.release(faces)
    end
  end)

  -- Marks every node of every panel for restyling, re-expansion, and redrawing at the next commit.
  local function invalidateAll(): ()
    for _, entry in live do
      tree.invalidate(entry.record)
    end
  end

  local function retheme(): ()
    current = themes.resolve(mode, accent)
    invalidateAll()
  end

  frameService:onUpdate(context, {
    phase = 'scene',
    order = -100,
    run = function(dt: number): ()
      -- Overlays opened during this loop are appended to the list and committed after their openers.
      local head = presentation.head()
      local index = 1
      while index <= #live do
        local entry = live[index]
        presentation.place(entry.record, head, dt, current)
        panels.commit(provider, entry.record)
        overlay.place(provider, entry.record)
        input.animate(entry.record, dt, current.motion.crisp)
        index += 1
      end
      if settings.controllerTraversal then
        traversal.controllers(traverse, input.pointing(router))
      end
    end,
  })

  if settings.touch then
    frameService:onUpdate(context, {
      phase = 'pointing',
      order = 100,
      run = function(dt: number): ()
        local panels: { records.Panel } = {}
        for _, entry in live do
          panels[#panels + 1] = entry.record
        end
        touch.update(touching, panels, env, router, dt)
      end,
    })
  end

  frameService:onDraw(context, {
    phase = 'scene',
    order = 50,
    run = function(pass: Pass): ()
      if #live == 0 then
        return
      end
      if not resources then
        resources, releaseResources = renderer.acquire()
      end
      local held = assert(resources)
      for _, entry in live do
        local record = entry.record
        if record.visible and record.root and record.width > 0 and record.height > 0 then
          protected.call(`ui: panel '{record.name}' draw`, function(): ()
            layout.place(record)
            local packed = pack.run(record, env, function(name: string): { uiHost.Visual }
              return registry.visuals(kinds, name)
            end, entry.packed)
            entry.packed = packed
            for _, marker in touching.markers do
              if marker.panel == record then
                pack.marker(packed, marker.x, marker.y, marker.surface, marker.depth, current)
              end
            end
            renderer.draw(held, pass, record, assert(entry.packed), current, faces)
          end)
        end
      end
      renderer.endFrame(held)
    end,
  })

  local service: uiHost.Service
  service = {
    newPanel = function(_self: uiHost.Service, owner: plugin.Owner, options: uiHost.PanelOptions): uiHost.Panel
      context:checkOwner(owner)
      for _, entry in live do
        assert(entry.record.name ~= options.name, `ui: the panel name '{options.name}' is in use`)
      end
      local record, handle = panels.new(provider, owner, options)
      recordsOf[handle] = record
      context:acquire(owner, function(): () -> ()
        return function(): ()
          handle:destroy()
        end
      end)
      return handle
    end,
    registerKind = function(
      _self: uiHost.Service,
      owner: plugin.Owner,
      registration: uiHost.KindRegistration
    ): uiHost.Constructor
      context:checkOwner(owner)
      registry.validate(registration)
      context:acquire(owner, function(): () -> ()
        local remove = registry.addKind(kinds, owner, registration)
        reportedMissing[registration.name] = nil
        invalidateAll()
        return function(): ()
          remove()
          invalidateAll()
        end
      end)
      local name = registration.name
      return function(props: { [any]: any }?): uiHost.Element
        return uiHost.element(name, props)
      end
    end,
    registerVisual = function(
      _self: uiHost.Service,
      owner: plugin.Owner,
      name: string,
      visual: uiHost.Visual
    ): plugin.Effect
      context:checkOwner(owner)
      return context:acquire(owner, function(): () -> ()
        local remove = registry.addVisual(kinds, owner, name, visual)
        invalidateAll()
        return function(): ()
          remove()
          invalidateAll()
        end
      end)
    end,
    registerFont = function(_self: uiHost.Service, owner: plugin.Owner, font: uiHost.FontRegistration): plugin.Effect
      context:checkOwner(owner)
      assert(
        type(font) == 'table' and type(font.family) == 'string' and type(font.file) == 'string',
        'ui: a font names a family and a file'
      )
      return context:acquire(owner, function(): () -> ()
        return fonts.add(faces, font.family, font.weight or 400, font.file)
      end)
    end,
    theme = function(_self: uiHost.Service): uiHost.Theme
      return current
    end,
    setMode = function(_self: uiHost.Service, given: 'dark' | 'light'): ()
      assert(given == 'dark' or given == 'light', `ui: '{tostring(given)}' is not a theme mode`)
      if given ~= mode then
        mode = given
        retheme()
      end
    end,
    setAccent = function(_self: uiHost.Service, given: uiHost.Color): ()
      assert(type(given) == 'table' and #given >= 3, 'ui: an accent is a colour')
      accent = table.freeze { given[1], given[2], given[3], given[4] or 1 }
      retheme()
    end,
    navigate = function(_self: uiHost.Service, direction: string): boolean
      local codes = keys.CODES
      if direction == 'next' or direction == 'previous' then
        return traversal.key(traverse, codes.tab, 'controller', if direction == 'previous' then { 'shift' } else {})
      end
      local code = (codes :: any)[direction]
      assert(type(code) == 'number', `ui: '{tostring(direction)}' is not a direction`)
      return traversal.key(traverse, code, 'controller')
    end,
    activate = function(_self: uiHost.Service): boolean
      return traversal.key(traverse, keys.CODES.enter, 'controller')
    end,
    dismiss = function(_self: uiHost.Service): boolean
      return traversal.key(traverse, keys.CODES.escape, 'controller')
    end,
    nextPanel = function(_self: uiHost.Service): boolean
      return traversal.nextPanel(traverse)
    end,
    find = function(_self: uiHost.Service, id: string): uiHost.Node?
      for _, entry in live do
        local name = entry.record.name
        if string.sub(id, 1, #name + 1) == name .. ':' then
          return panels.find(entry.record, string.sub(id, #name + 2))
        end
      end
      return nil
    end,
    inspect = function(_self: uiHost.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      for _, entry in live do
        local record = entry.record
        local count = 0
        for _ in record.nodes do
          count += 1
        end
        table.insert(
          result,
          inspection.registration('panel', 'ui-host.newPanel', record.owner, record.name, not record.dead, {
            width = record.width,
            height = record.height,
            nodes = count,
            visible = record.visible,
          })
        )
      end
      return inspection.snapshot(result, { mode = mode }, { 'kind and visual callbacks are not run' })
    end,
  }
  return service
end

return plugin.provider<<Config, Settings, uiHost.Service>> {
  name = 'ui-host',
  schema = config.schema,
  capability = uiHost.capability,
  requires = { frame.capability, surfaces.capability, focusContract.capability },
  build = build,
}
