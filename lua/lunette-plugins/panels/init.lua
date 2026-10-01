-- A neutral panels provider.
--
-- Each activation owns one independent registry. Panel acquisition is tied to the
-- caller's owner, while queries remain usable without an owner. No module-global
-- teardown, signal, or cleanup registry is used: the plugin context owns all
-- provider resources through effects, and a panel's end is announced to
-- owner-scoped removal listeners.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'
local quad = require '@lunette-contracts/quad'
local panel = require '@lunette-plugins/panels/panel'
local events = require '@lunette-plugins/panels/events'

export type Service = contracts.Service
export type Owner = contracts.Owner
export type Options = contracts.Options
export type Panel = contracts.Panel
export type WindowPanel = contracts.WindowPanel
export type MonitorPanel = contracts.MonitorPanel

type ProviderState = {
  active: boolean,
  context: plugin.Context,
  panels: { panel.State },
  opaqueShader: Shader?,
  events: events.Registry,
  host: panel.Host,
}

local OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]]

-- Everything a panel's appearance is tuned with, in one table. Each activation
-- receives its own frozen copy, so no consumer can retune another's panels.
local function style(): contracts.Style
  return table.freeze {
    borderThickness = 0.008,
    borderDepth = 0.001,
    borderColor = table.freeze { 0.14, 0.14, 0.17, 0.95 },
    borderHighlightColor = table.freeze { 0.35, 0.55, 0.95, 0.95 },
    titleHeight = 0.04,
    titleMargin = 0.02,
    titleColor = table.freeze { 1, 1, 1, 1 },
  }
end

local function livePanels(state: ProviderState): { Panel }
  local live: { Panel } = {}
  for _, target in ipairs(state.panels) do
    if not target.dead then
      live[#live + 1] = target
    end
  end
  return live
end

local function opaqueShader(state: ProviderState): Shader?
  if not state.active or not state.context:active() then
    return nil
  end
  if state.opaqueShader then
    return state.opaqueShader
  end
  if not (lovr and lovr.graphics and lovr.graphics.newShader) then
    return nil
  end
  state.context:effect(function()
    local shader = lovr.graphics.newShader('unlit', OPAQUE_FRAGMENT)
    state.opaqueShader = shader
    return function()
      shader:release()
      state.opaqueShader = nil
    end
  end)
  return state.opaqueShader
end

-- Registers a panel with the owner's lifetime. The claim is acquired inside the
-- acquisition, so a claim that fails leaves nothing registered.
local function create(state: ProviderState, owner: Owner, source: panel.Source, options: Options?): panel.State
  state.context:checkOwner(owner)
  local target = panel.new(state.host, owner, source, options)
  local acquired = owner:effect(function()
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
  events.emitAdded(state.events, state.context, target)
  return target
end

-- Checks a listener table's shape. Each error names the caller of the
-- service method, two frames up.
local function checkListener(operation: string, listener: unknown): ()
  if type(listener) ~= 'table' then
    error(string.format('panels %s: a listener is a table of fields, not a %s', operation, type(listener)), 3)
  end
  for key, _ in listener :: { [unknown]: unknown } do
    if key ~= 'panel' and key ~= 'run' then
      error(string.format('panels %s: unknown field %s; the fields are panel and run', operation, tostring(key)), 3)
    end
  end
  local run = (listener :: { [string]: unknown }).run
  if type(run) ~= 'function' then
    error(string.format('panels %s: run is a function, not a %s', operation, type(run)), 3)
  end
end

local function init(context: plugin.Context): Service
  local state: ProviderState
  local host: panel.Host = {
    active = function(): boolean
      return state.active
    end,
    checkOwner = function(owner: Owner)
      context:checkOwner(owner)
    end,
    style = style(),
    opaqueShader = function(): Shader?
      return opaqueShader(state)
    end,
    removed = function(target: panel.State)
      local index = table.find(state.panels, target)
      if index then
        table.remove(state.panels, index)
      end
      events.emitRemoved(state.events, context, target)
    end,
  }
  local created: ProviderState = {
    active = true,
    context = context,
    panels = {},
    opaqueShader = nil,
    events = events.new(),
    host = host,
  }
  state = created
  -- Registered first, so it runs last: the panels the activation still holds
  -- are released while removal listeners can hear it, and only then are the
  -- listeners cleared.
  context:effect(function()
    return function()
      state.active = false
      for _, target in ipairs(table.clone(state.panels)) do
        panel.retire(target)
      end
      events.clear(state.events)
    end
  end)

  -- The published service is revoked with this activation, so its methods
  -- need no liveness guard. Panels are not reached through the service after
  -- they are created, and they check their activation through their host.
  local service: Service = {
    STYLE = host.style,
    DEFAULT_PRIORITY = panel.DEFAULT_PRIORITY,
    DEFAULT_HEIGHT = panel.DEFAULT_HEIGHT,
    DEFAULT_ASPECT = panel.DEFAULT_ASPECT,
    OPAQUE_FRAGMENT = OPAQUE_FRAGMENT,
    rayQuadHit = function(_self: Service, target: contracts.Quad, origin: vector, direction: vector)
      return quad.hit(target, origin, direction)
    end,
    fromWindow = function(_self: Service, owner: Owner, window: lunette.Window, options: Options?): WindowPanel
      local target = create(state, owner, { kind = 'window', source = window }, options)
      if target.kind ~= 'window' then
        error 'panels: window constructor returned a monitor panel'
      end
      return target
    end,
    fromMonitor = function(_self: Service, owner: Owner, monitor: lunette.Monitor, options: Options?): MonitorPanel
      local target = create(state, owner, { kind = 'monitor', source = monitor }, options)
      if target.kind ~= 'monitor' then
        error 'panels: monitor constructor returned a window panel'
      end
      return target
    end,
    all = function(_self: Service): { Panel }
      return livePanels(state)
    end,
    -- A panel whose source has died is not answered, even before the next
    -- update retires it, so a source that comes back under the same identity
    -- before then is not taken for the old one.
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
      for _, target in ipairs(livePanels(state)) do
        target:update()
      end
    end,
    draw = function(_self: Service, pass: Pass)
      for _, target in ipairs(livePanels(state)) do
        target:draw(pass)
      end
    end,
    opaqueShader = function(_self: Service, owner: Owner): Shader?
      context:checkOwner(owner)
      return opaqueShader(state)
    end,
    onDropped = function(_self: Service, owner: Owner, listener: contracts.DroppedListener): plugin.Effect
      checkListener('onDropped', listener)
      return events.onDropped(state.events, context, owner, listener.panel, listener.run)
    end,
    emitDropped = function(_self: Service, owner: Owner, target: Panel, pointer: vocabulary.Pointer)
      events.emitDropped(state.events, context, owner, target, pointer)
    end,
    onAdded = function(_self: Service, owner: Owner, callback: contracts.PanelCallback): plugin.Effect
      return events.onAdded(state.events, context, owner, callback)
    end,
    onRemoved = function(_self: Service, owner: Owner, listener: contracts.RemovedListener): plugin.Effect
      checkListener('onRemoved', listener)
      return events.onRemoved(state.events, context, owner, listener.panel, listener.run)
    end,
  }
  return service
end

local capability = contracts.capability
local provided = { panels = capability }

return plugin.define {
  name = 'panels',
  provides = provided,
  init = function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    publish:provide(capability, init(context))
  end,
}
