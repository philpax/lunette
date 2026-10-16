-- Provides the UI toolkit host: panels with mount points, element kinds and visuals, layout, routing, and drawing.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
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
  local mode: themes.Mode = settings.mode
  local accent: uiHost.Color = settings.accent or themes.DEFAULT_ACCENT
  local current = themes.resolve(mode, accent)
  local kinds = registry.new(context)
  local faces = fonts.new()
  local router = input.new()
  local touching = touch.new()
  local live: { Live } = {}
  local reportedMissing: { [string]: boolean } = {}
  local resources: renderer.Resources? = nil
  local releaseResources: (() -> ())? = nil

  local env: records.Environment
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
    dispatch = function(node: records.Node, event: uiHost.Event): ()
      input.dispatch(env, node, event)
    end,
  }

  local provider: panels.Provider = {
    env = env,
    router = router,
    offer = function(record: records.Panel, surface: vocabulary.Surface): ()
      table.insert(live, { record = record, surface = surface })
    end,
    release = function(record: records.Panel): ()
      for index, entry in live do
        if entry.record == record then
          table.remove(live, index)
          break
        end
      end
    end,
  }

  surfaceService:offer(context, {
    name = 'ui-host',
    list = function(): { vocabulary.Surface }
      local list: { vocabulary.Surface } = {}
      for _, entry in live do
        if entry.record.visible and entry.record.width > 0 then
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

  local function retheme(): ()
    current = themes.resolve(mode, accent)
    for _, entry in live do
      tree.invalidate(entry.record)
    end
  end

  frameService:onUpdate(context, {
    phase = 'scene',
    order = -100,
    run = function(dt: number): ()
      for _, entry in table.clone(live) do
        panels.commit(provider, entry.record)
        input.animate(entry.record, dt, current.motion.crisp)
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
    end,
  })

  local service: uiHost.Service
  service = {
    newPanel = function(_self: uiHost.Service, owner: plugin.Owner, options: uiHost.PanelOptions): uiHost.Panel
      context:checkOwner(owner)
      for _, entry in live do
        assert(entry.record.name ~= options.name, `ui: the panel name '{options.name}' is in use`)
      end
      local _, handle = panels.new(provider, owner, options)
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
        return registry.addKind(kinds, owner, registration)
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
        return function(): ()
          remove()
          for _, entry in live do
            tree.invalidate(entry.record)
          end
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
  requires = { frame.capability, surfaces.capability },
  build = build,
}
