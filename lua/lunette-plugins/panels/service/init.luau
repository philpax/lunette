-- Each activation owns its panel registry and resources.
-- See lua/lunette-plugins/panels/README.md for options.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local panel = require '@self/private/panel'
local listeners = require '@lunette-plugins/registration/listeners'
local inspection = require '@lunette-contracts/inspection'
local theme = require '@lunette-contracts/theme'
local appearance = require '@self/private/appearance'
local frame = require '@self/private/frame'
local clientPixels = require '@lunette-plugins/graphics/client-pixels'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Options = contracts.Options
export type Panel = contracts.Panel
export type WindowPanel = contracts.WindowPanel
export type MonitorPanel = contracts.MonitorPanel

type RemovedListener = {
  read panel: Panel?,
  read callback: contracts.PanelCallback,
}

type ProviderState = {
  active: boolean,
  context: plugin.Context,
  panels: { panel.State },
  shaders: clientPixels.Shaders,
  added: listeners.Listeners<contracts.PanelCallback>,
  lockChanged: listeners.Listeners<contracts.PanelCallback>,
  curveChanged: listeners.Listeners<contracts.PanelCallback>,
  transformLockChanged: listeners.Listeners<contracts.PanelCallback>,
  removed: listeners.Listeners<RemovedListener>,
  host: panel.Host,
  -- Whether the headset composites curved layers; the service refreshes it once per update.
  layerCurve: boolean,
}

local config = require '@self/config'
local schema = require '@lunette-plugin/schema'

export type Settings = config.Settings

export type Config = config.Config

local function livePanels(state: ProviderState): { Panel }
  local live: { Panel } = {}
  for _, target in ipairs(state.panels) do
    if not target.dead then
      live[#live + 1] = target
    end
  end
  return live
end

-- A failed initial claim leaves the panel unregistered.
local function create(state: ProviderState, owner: Owner, source: panel.Source, options: Options?): panel.State
  state.context:checkOwner(owner)
  local target = panel.new(state.host, owner, source, options)
  local acquired = state.context:acquire(owner, function(): () -> ()
    state.panels[#state.panels + 1] = target
    local ok, failure = pcall(panel.claim, target)
    if not ok then
      local index = table.find(state.panels, target)
      if index then
        table.remove(state.panels, index)
      end
      target.dead = true
      error(failure, 0)
    end
    return function()
      target.effect = nil
      panel.release(target)
    end
  end)
  if target.dead then
    acquired:dispose()
    return target
  end
  target.effect = acquired
  state.added:each('panels: added listener', function(callback: contracts.PanelCallback)
    callback(target)
  end)
  return target
end

local REMOVED_KEYS: { string } = { 'panel', 'run' }

local function supportsLayerCurve(): boolean
  local features = lovr.headset.getFeatures()
  return features.layerCurve == true
end

local function build(context: plugin.Context, settings: Settings): Service
  local themes = context:require(theme.capability)
  local paint = appearance.prepare(themes:current(), settings)
  local state: ProviderState
  local function currentPaint(): appearance.Paint
    if not state.active or not context:active() then
      return paint
    end
    local current = themes:current()
    if current ~= paint.theme then
      paint = appearance.prepare(current, settings)
    end
    return paint
  end
  local host: panel.Host = {
    active = function(): boolean
      return state.active
    end,
    checkOwner = function(owner: Owner)
      context:checkOwner(owner)
    end,
    acquire = function(owner: Owner, acquire: () -> () -> ()): plugin.Effect
      return context:acquire(owner, acquire)
    end,
    settings = settings,
    paint = currentPaint,
    contentShader = function(opaque: boolean): Shader?
      return state.shaders.choose(opaque)
    end,
    lockChanged = function(target: panel.State)
      state.lockChanged:each('panels: lock listener', function(callback: contracts.PanelCallback)
        callback(target)
      end)
    end,
    curveChanged = function(target: panel.State)
      state.curveChanged:each('panels: curve listener', function(callback: contracts.PanelCallback)
        callback(target)
      end)
    end,
    transformLockChanged = function(target: panel.State)
      state.transformLockChanged:each('panels: transform lock listener', function(callback: contracts.PanelCallback)
        callback(target)
      end)
    end,
    layerCurve = function(): boolean
      return state.layerCurve
    end,
    removed = function(target: panel.State)
      local index = table.find(state.panels, target)
      if index then
        table.remove(state.panels, index)
      end
      state.removed:each('panels: removed listener', function(listener: RemovedListener)
        listener.callback(target)
      end, function(listener: RemovedListener): boolean
        return listener.panel == nil or listener.panel == target
      end)
    end,
  }
  local created: ProviderState = {
    active = true,
    context = context,
    panels = {},
    shaders = clientPixels.shaders(context, function(): boolean
      return state.active
    end),
    added = listeners.new<<contracts.PanelCallback>>(context),
    lockChanged = listeners.new<<contracts.PanelCallback>>(context),
    curveChanged = listeners.new<<contracts.PanelCallback>>(context),
    transformLockChanged = listeners.new<<contracts.PanelCallback>>(context),
    removed = listeners.new<<RemovedListener>>(context),
    host = host,
    layerCurve = supportsLayerCurve(),
  }
  state = created
  -- This effect runs last, while removal listeners still have live owners.
  context:effect(function(): () -> ()
    return function()
      state.active = false
      for _, target in ipairs(table.clone(state.panels)) do
        panel.retire(target)
      end
      state.added:clear()
      state.lockChanged:clear()
      state.curveChanged:clear()
      state.transformLockChanged:clear()
      state.removed:clear()
    end
  end)

  local service: Service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result = state.added:inspect 'panels.onAdded'
      for _, entry in ipairs(state.removed:inspect 'panels.onRemoved') do
        result[#result + 1] = entry
      end
      for _, entry in ipairs(state.curveChanged:inspect 'panels.onCurveChanged') do
        result[#result + 1] = entry
      end
      for _, entry in ipairs(state.transformLockChanged:inspect 'panels.onTransformLockChanged') do
        result[#result + 1] = entry
      end
      local claims, meshes = 0, 0
      for _, target in ipairs(state.panels) do
        if target.claim then
          claims += 1
        end
        if target.mesh then
          meshes += 1
        end
        if target.outline and target.outline.mesh then
          meshes += 1
        end
        local attached = target.frame
        if attached and attached.live then
          result[#result + 1] = inspection.registration(
            'membership',
            'panels.attachFrame',
            attached.owner,
            target.title,
            state.active and context:owns(attached.owner) and not target.dead and not target.source.dead,
            {
              sourceId = target.source.id,
              sourceKind = target.kind,
              joined = frame.joined(attached),
              headerHeight = attached.style.headerHeight,
              headerRadius = attached.style.headerRadius,
              borderThickness = attached.style.borderThickness,
            }
          )
        end
        local live = state.active and context:owns(target.owner) and not target.dead and not target.source.dead
        result[#result + 1] = inspection.registration(
          'panel',
          'panels.from' .. (if target.kind == 'window' then 'Window' else 'Monitor'),
          target.owner,
          target.title,
          live,
          {
            sourceId = target.source.id,
            sourceKind = target.kind,
            sourceDead = target.source.dead,
            width = target.width,
            height = target.height,
            hidden = target.hidden,
            locked = target.locked,
            transformLocked = target.transformLocked,
            curve = target.curve,
            priority = target.priority,
            layerClaim = target.claim ~= nil,
            mesh = target.mesh ~= nil,
            outlineMesh = target.outline ~= nil and target.outline.mesh ~= nil,
          }
        )
        for index, override in ipairs(target.overrides) do
          result[#result + 1] = inspection.registration(
            'visibility',
            'panels.setHidden',
            override.owner,
            target.title,
            state.active and context:owns(override.owner) and not target.dead,
            {
              sourceId = target.source.id,
              sourceKind = target.kind,
              hidden = override.hidden,
              current = index == #target.overrides,
            }
          )
        end
      end
      return inspection.snapshot(result, {
        active = state.active,
        layerClaims = claims,
        layerCurve = state.layerCurve,
        meshes = meshes,
        opaqueShader = state.shaders.held(true),
      })
    end,
    fromWindow = function(_self: Service, owner: Owner, window: lunette.Window, options: Options?): WindowPanel
      return (create(state, owner, { kind = 'window', source = window }, options) :: unknown) :: WindowPanel
    end,
    fromMonitor = function(_self: Service, owner: Owner, monitor: lunette.Monitor, options: Options?): MonitorPanel
      return (create(state, owner, { kind = 'monitor', source = monitor }, options) :: unknown) :: MonitorPanel
    end,
    all = function(_self: Service): { Panel }
      return livePanels(state)
    end,
    -- A dead source does not match a replacement with the same identity until update retires its panel.
    forSource = function(_self: Service, source: contracts.Source): Panel?
      if source == nil then
        return nil
      end
      local identity = source.id
      for _, target in ipairs(state.panels) do
        if not target.dead and not target.source.dead and target.source.id == identity then
          return target
        end
      end
      return nil
    end,
    update = function(_self: Service)
      state.layerCurve = supportsLayerCurve()
      currentPaint()
      for _, target in ipairs(livePanels(state)) do
        target:update()
      end
    end,
    draw = function(_self: Service, pass: Pass)
      currentPaint()
      for _, target in ipairs(livePanels(state)) do
        target:draw(pass)
      end
    end,
    isInputLocked = function(_self: Service, sink: lunette.Sink): boolean
      for _, target in ipairs(state.panels) do
        if not target.dead and not target.source.dead and target.locked and target.source.sink == sink then
          return true
        end
      end
      return false
    end,
    onLockChanged = function(_self: Service, owner: Owner, listener: contracts.AddedListener): plugin.Effect
      listeners.check('panels onLockChanged', listener)
      return state.lockChanged:add(owner, listener.run)
    end,
    onCurveChanged = function(_self: Service, owner: Owner, listener: contracts.AddedListener): plugin.Effect
      listeners.check('panels onCurveChanged', listener)
      return state.curveChanged:add(owner, listener.run)
    end,
    onTransformLockChanged = function(_self: Service, owner: Owner, listener: contracts.AddedListener): plugin.Effect
      listeners.check('panels onTransformLockChanged', listener)
      return state.transformLockChanged:add(owner, listener.run)
    end,
    onAdded = function(_self: Service, owner: Owner, listener: contracts.AddedListener): plugin.Effect
      listeners.check('panels onAdded', listener)
      return state.added:add(owner, listener.run)
    end,
    onRemoved = function(_self: Service, owner: Owner, listener: contracts.RemovedListener): plugin.Effect
      listeners.check('panels onRemoved', listener, REMOVED_KEYS)
      local target = listener.panel
      local details = if target then { sourceId = target.source.id, sourceKind = target.kind } else {}
      return state.removed:add(owner, { panel = target, callback = listener.run }, details)
    end,
  }
  return service
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'panels',
  capability = contracts.capability,
  requires = { theme.capability },
  schema = config.schema :: schema.Schema<Config, Settings>,
  build = build,
}
