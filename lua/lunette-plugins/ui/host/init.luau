-- Provides the UI toolkit host: panels with mount points, element kinds and visuals, layout, routing, and drawing.

local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local frame = require '@lunette-contracts/frame'
local surfaces = require '@lunette-contracts/surfaces'
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-contracts/interaction'
local keys = require '@lunette-contracts/keys'
local vocabulary = require '@lunette-contracts/vocabulary'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/diagnostics/protected-call'
local themeContract = require '@lunette-contracts/theme'
local config = require '@self/config'
local records = require '@self/private/records'
local registry = require '@self/private/registry'
local tree = require '@self/private/tree'
local layout = require '@self/private/layout'
local input = require '@self/private/input'
local touch = require '@self/private/touch'
local overlay = require '@self/private/overlay'
local presentation = require '@self/private/presentation'
local traversal = require '@self/private/traversal'
local chord = require '@self/private/chord'
local motion = require '@self/private/motion'
local semantics = require '@self/private/semantics'
local panels = require '@self/private/panel'
local outlets = require '@self/private/outlets'
local placements = require '@self/private/placements'
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
  local interactionService = context:require(interaction.capability)
  local traverse: traversal.Traversal
  local themeService = context:require(themeContract.capability)
  local current = themeService:current()
  local kinds = registry.new(context)
  local contributions = outlets.new()
  local faces = fonts.new()
  local router = input.new()
  local touching = touch.new()
  local live: { Live } = {}
  local access: uiHost.AccessibilityOptions = {}
  local recordsOf: { [uiHost.Panel]: records.Panel } = setmetatable({}, { __mode = 'k' }) :: any
  local reportedMissing: { [string]: boolean } = {}
  local held = chord.new()
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
      placements.removed(contributions, env, node)
    end,
    outlet = function(_panel: records.Panel, node: records.Node): ({ uiHost.Element }, { string })
      return placements.children(contributions, env, node)
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
    haptics = function(): boolean
      return access.haptics ~= false
    end,
    pulse = function(node: records.Node, event: 'detent'): ()
      if access.haptics ~= false then
        input.pulse(router, node, event)
      end
    end,
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
    surfaceOf = function(record: records.Panel): vocabulary.Surface?
      for _, entry in live do
        if entry.record == record then
          return entry.surface
        end
      end
      return nil
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

  -- A press on a window, another plugin's surface, or nothing dismisses every overlay; presses on host panels are
  -- judged against each overlay's chain as they are routed.
  interactionService:onPress(context, {
    run = function(target: vocabulary.Surface?): ()
      for _, entry in live do
        if entry.surface == target then
          return
        end
      end
      for _, entry in table.clone(live) do
        local relation = entry.record.overlay
        if relation and not entry.record.dead and not entry.record.closing then
          relation.portal.handle:emit 'onDismiss'
        end
      end
    end,
  })

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
  local function livePanels(): { records.Panel }
    local list: { records.Panel } = {}
    for _, entry in live do
      list[#list + 1] = entry.record
    end
    return list
  end

  local function invalidateAll(): ()
    for _, entry in live do
      tree.invalidate(entry.record)
    end
  end

  -- Default appearance draws with the base theme; the accessibility settings apply in either appearance.
  local function retheme(): ()
    current = if kinds.defaultAppearance then themeService:base() else themeService:current()
    invalidateAll()
  end
  themeService:onChanged(context, { run = retheme })

  local function setDefaultAppearance(on: boolean): ()
    if kinds.defaultAppearance ~= on then
      kinds.defaultAppearance = on
      retheme()
    end
  end

  frameService:onUpdate(context, {
    phase = 'scene',
    order = -100,
    run = function(dt: number): ()
      -- Overlays opened during this loop are appended to the list and committed after their openers.
      local head = presentation.head()
      local faded: { records.Panel } = {}
      local index = 1
      while index <= #live do
        local entry = live[index]
        presentation.place(entry.record, head, dt, current)
        panels.commit(provider, entry.record)
        overlay.place(provider, entry.record)
        -- Reduced motion snaps every channel to its target.
        local record = entry.record
        motion.panel(record, dt, if access.reducedMotion then 0 else current.motion.crisp)
        if record.closing and (record.fade == nil or record.fade.value <= 0.02) then
          table.insert(faded, record)
        end
        index += 1
      end
      for _, record in faded do
        panels.destroy(provider, record)
      end
      if settings.controllerTraversal then
        traversal.controllers(traverse, input.pointing(router))
      end
      if settings.appearanceChord then
        local left, right = chord.read()
        if chord.step(held, left, right, dt) then
          setDefaultAppearance(not kinds.defaultAppearance)
        end
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
        touch.update(touching, panels, env, router, dt, function(hand: 'left' | 'right', near: boolean): ()
          interactionService:reportNear(context, hand, near)
        end)
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
        -- A glyph the atlas cannot generate draws nothing and is reported once.
        resources, releaseResources = renderer.acquire(function(failure: string): ()
          protected.call('ui: glyph atlas', function(): ()
            error(failure, 0)
          end)
        end)
      end
      local held = assert(resources)
      renderer.beginFrame(held)
      local drawn: { records.Panel } = {}
      for _, entry in live do
        drawn[#drawn + 1] = entry.record
      end
      for _, entry in live do
        local record = entry.record
        if record.visible and record.root and record.width > 0 and record.height > 0 then
          protected.call(`ui: panel '{record.name}' draw`, function(): ()
            layout.place(record)
            local packed = pack.run(record, env, function(name: string): { uiHost.Visual }
              return registry.visuals(kinds, name)
            end, renderer.glyphs(held), entry.packed)
            entry.packed = packed
            for _, marker in touching.markers do
              if marker.panel == record then
                pack.marker(packed, marker.x, marker.y, marker.surface, marker.depth, current)
              end
            end
            renderer.draw(held, pass, record, assert(entry.packed), current, presentation.blocked(record, drawn))
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
        local remove, skipped = registry.addKind(kinds, owner, registration)
        for _, failure in skipped do
          protected.call(`ui: override of {registration.name}`, function(): ()
            error(failure.message, 0)
          end)
        end
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
    overrideKind = function(
      _self: uiHost.Service,
      owner: plugin.Owner,
      name: string,
      registration: uiHost.KindRegistration
    ): plugin.Effect
      context:checkOwner(owner)
      registry.validate(registration)
      return context:acquire(owner, function(): () -> ()
        local remove = registry.overrideKind(kinds, owner, name, registration)
        invalidateAll()
        return function(): ()
          remove()
          invalidateAll()
        end
      end)
    end,
    contribute = function(
      _self: uiHost.Service,
      owner: plugin.Owner,
      outlet: uiHost.Outlet<any>,
      contribution: uiHost.Contribution
    ): plugin.Effect
      context:checkOwner(owner)
      local version = outlets.prepare(contributions, outlet, contribution)
      local bind = contribution.bind
      return context:acquire(owner, function(): () -> ()
        local record, remove = outlets.add(contributions, owner, outlet, version, bind)
        return function(): ()
          remove()
          placements.ended(contributions, env, record)
        end
      end)
    end,
    setDefaultAppearance = function(_self: uiHost.Service, on: boolean): ()
      assert(type(on) == 'boolean', 'ui: default appearance is on or off')
      setDefaultAppearance(on)
    end,
    defaultAppearance = function(_self: uiHost.Service): boolean
      return kinds.defaultAppearance
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
      themeService:setMode(given)
    end,
    setAccessibility = function(_self: uiHost.Service, options: uiHost.AccessibilityOptions): ()
      assert(type(options) == 'table', 'ui: accessibility options are a table')
      local scale = options.textScale
      assert(
        scale == nil or (type(scale) == 'number' and scale >= 0.5 and scale <= 2),
        'ui: a text scale is from 0.5 to 2'
      )
      access = table.freeze(table.clone(options))
      themeService:setOptions { textScale = options.textScale, highContrast = options.highContrast }
    end,
    accent = function(_self: uiHost.Service): uiHost.Color
      return themeService:accent()
    end,
    setAccent = function(_self: uiHost.Service, given: uiHost.Color): ()
      themeService:setAccent(given)
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
    inspectNodes = function(_self: uiHost.Service): inspection.Snapshot
      local result: { inspection.Registration } = {}
      -- Every node with a role is reported with its semantics, state, and box, so tests and assistive plugins can
      -- find it by id or by role and name.
      for _, node in semantics.nodes(livePanels()) do
        local described = semantics.of(env, node)
        local details: { [string]: string | number | boolean } = {
          kind = node.kind.name,
          role = semantics.role(node) or 'group',
          x = node.x,
          y = node.y,
          width = node.width,
          height = node.height,
          focused = node.host.focused,
          hovered = node.host.hovers > 0,
          enabled = not described.disabled and node.props.disabledReason == nil,
        }
        if described.name then
          details.label = described.name
        end
        if described.value ~= nil then
          details.value = described.value
        end
        for _, flag in { 'checked', 'selected', 'expanded' } do
          local value = (described :: any)[flag]
          if value ~= nil then
            details[flag] = value
          end
        end
        if type(node.props.disabledReason) == 'string' then
          details.disabledReason = node.props.disabledReason
        end
        table.insert(
          result,
          inspection.registration(
            'control',
            'ui-host.node',
            placements.ownerOf(node),
            semantics.id(node),
            not node.dead,
            details
          )
        )
      end
      return inspection.snapshot(result, nil, { 'kind semantics run under a protected call; visuals do not run' })
    end,
    findByRole = function(_self: uiHost.Service, role: uiHost.Role, name: string): uiHost.Node?
      for _, node in semantics.nodes(livePanels()) do
        if semantics.role(node) == role and semantics.of(env, node).name == name then
          return node.handle
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
            presentation = record.presentation,
          })
        )
      end
      -- Overrides are listed with their owners, so the manager shows which plugin changed which kind or visual.
      for _, override in registry.overridden(kinds) do
        table.insert(
          result,
          inspection.registration('override', 'ui-host.override', override.owner, override.name, true, {
            replaces = override.kind,
            active = not kinds.defaultAppearance,
          })
        )
      end
      -- Contributions are listed with their owners and the number of placements each renders in.
      for _, entry in outlets.inspect(contributions) do
        local contribution = entry.contribution
        table.insert(
          result,
          inspection.registration('contribution', 'ui-host.contribute', contribution.owner, contribution.outlet, true, {
            contributor = contribution.contributor,
            version = `{contribution.version.major}.{contribution.version.minor}`,
            placements = entry.placements,
          })
        )
      end
      return inspection.snapshot(
        result,
        { mode = current.mode, defaultAppearance = kinds.defaultAppearance },
        { 'kind and visual callbacks are not run' }
      )
    end,
  }
  return service
end

return plugin.provider<<Config, Settings, uiHost.Service>> {
  name = 'ui-host',
  schema = config.schema,
  capability = uiHost.capability,
  requires = {
    frame.capability,
    surfaces.capability,
    focusContract.capability,
    interaction.capability,
    themeContract.capability,
  },
  build = build,
}
