-- Each activation owns its panel registry and resources.
-- See docs/dev/lua-api.md#panels for options.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contracts = require '@lunette-contracts/panels'
local panel = require '@lunette-plugins/panels/panel'
local listeners = require '@lunette-plugins/listeners'
local inspection = require '@lunette-contracts/inspection'
local theme = require '@lunette-contracts/theme'
local appearance = require '@lunette-plugins/panels/appearance'
local frame = require '@lunette-plugins/panels/frame'

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
  opaqueShader: Shader?,
  alphaShader: Shader?,
  added: listeners.Listeners<contracts.PanelCallback>,
  removed: listeners.Listeners<RemovedListener>,
  host: panel.Host,
}

local OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    vec3 linear = gammaToLinear(getPixel(ColorTexture, UV).rgb);
    return vec4(linear * Color.rgb * Color.a, Color.a);
  }
]]
local ALPHA_FRAGMENT = [[
  vec4 lovrmain() {
    vec4 pixel = getPixel(ColorTexture, UV);
    if (pixel.a <= 0.) return vec4(0.);
    vec3 linear = gammaToLinear(clamp(pixel.rgb / pixel.a, 0., 1.));
    float alpha = pixel.a * Color.a;
    return vec4(linear * Color.rgb * alpha, alpha);
  }
]]

local config = require '@lunette-plugins/panels/config'
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

local function contentShader(state: ProviderState, opaque: boolean): Shader?
  if not state.active or not state.context:active() then
    return nil
  end
  local cached = if opaque then state.opaqueShader else state.alphaShader
  if cached then
    return cached
  end
  state.context:effect(function()
    local shader = lovr.graphics.newShader('unlit', if opaque then OPAQUE_FRAGMENT else ALPHA_FRAGMENT)
    if opaque then
      state.opaqueShader = shader
    else
      state.alphaShader = shader
    end
    return function()
      shader:release()
      if opaque then
        state.opaqueShader = nil
      else
        state.alphaShader = nil
      end
    end
  end)
  return if opaque then state.opaqueShader else state.alphaShader
end

-- A failed initial claim leaves the panel unregistered.
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
  state.added:each('panels: added listener', function(callback)
    callback(target)
  end)
  return target
end

local LISTENER_KEYS: { [string]: boolean } = { panel = true, run = true }

-- Checks a listener table's shape. Each error names the caller of the
-- service method, two frames up.
local function checkListener(operation: string, listener: unknown): ()
  if type(listener) ~= 'table' then
    error(string.format('panels %s: a listener is a table of fields, not a %s', operation, type(listener)), 3)
  end
  plugin.rejectUnknownFields('panels ' .. operation, listener, LISTENER_KEYS, 'panel and run', 3)
  local run = (listener :: { [string]: unknown }).run
  if type(run) ~= 'function' then
    error(string.format('panels %s: run is a function, not a %s', operation, type(run)), 3)
  end
end

local function build(context: plugin.Context, settings: Settings): Service
  local broker = context:require(theme.capability)
  local paint = appearance.prepare(broker, settings, broker:current())
  local state: ProviderState
  local function currentPaint(): appearance.Paint
    if not state.active or not context:active() then
      return paint
    end
    local snapshot = broker:current()
    if snapshot.revision ~= paint.revision then
      paint = appearance.prepare(broker, settings, snapshot)
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
      return contentShader(state, opaque)
    end,
    removed = function(target: panel.State)
      local index = table.find(state.panels, target)
      if index then
        table.remove(state.panels, index)
      end
      state.removed:each('panels: removed listener', function(listener)
        listener.callback(target)
      end, function(listener)
        return listener.panel == nil or listener.panel == target
      end)
    end,
  }
  local created: ProviderState = {
    active = true,
    context = context,
    panels = {},
    opaqueShader = nil,
    alphaShader = nil,
    added = listeners.new<<contracts.PanelCallback>>(context),
    removed = listeners.new<<RemovedListener>>(context),
    host = host,
  }
  state = created
  broker:onChanged(context, function(_snapshot: theme.Snapshot): ()
    currentPaint()
  end)
  -- This effect runs last, while removal listeners still have live owners.
  context:effect(function()
    return function()
      state.active = false
      for _, target in ipairs(table.clone(state.panels)) do
        panel.retire(target)
      end
      state.added:clear()
      state.removed:clear()
    end
  end)

  -- Panels check activation liveness through their host.
  local service: Service = {
    inspect = function(_self: Service): inspection.Snapshot
      local result = state.added:inspect 'panels.onAdded'
      for _, entry in ipairs(state.removed:inspect 'panels.onRemoved') do
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
      return inspection.snapshot(
        result,
        { active = state.active, layerClaims = claims, meshes = meshes, opaqueShader = state.opaqueShader ~= nil }
      )
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
    onAdded = function(_self: Service, owner: Owner, callback: contracts.PanelCallback): plugin.Effect
      return state.added:add(owner, callback)
    end,
    onRemoved = function(_self: Service, owner: Owner, listener: contracts.RemovedListener): plugin.Effect
      checkListener('onRemoved', listener)
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
  requires = { theme = theme.capability },
  schema = config :: schema.Schema<Config, Settings>,
  build = build,
}
