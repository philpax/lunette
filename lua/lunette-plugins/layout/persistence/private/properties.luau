-- The one panel properties store: the curve, axis, input lock, and transform lock of every panel family, saved in a
-- versioned file keyed by PanelId. Pose, size, and tags stay with the arrangement. Panel families produce the value;
-- this store is the only writer.

local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local panelProperties = require '@lunette-contracts/panel-properties'
local frameContract = require '@lunette-contracts/frame'
local uiHostContract = require '@lunette-contracts/ui-host'
local versionedFile = require '@lunette-plugins/storage/versioned-file'
local curved = require '@lunette-plugins/graphics/curved-surface'
local slots = require './slots'
local format = require './format'
local capture = require './capture'

local properties = {}

properties.FILE = 'panel-properties.saved'
properties.VERSION = 1

local FIELDS: { [string]: boolean } = { curve = true, curveAxis = true, inputLocked = true, transformLocked = true }

export type Source = {
  -- The arrangement file as it first loaded, whose version 1 or 2 entries carry the input lock to migrate.
  read loaded: { format.Entry },
  read held: slots.Slots,
  read declined: () -> string?,
  read refuse: (string) -> (),
  read report: (string) -> (),
}

export type Store = {
  read bind: (
    Store,
    plugin.Context,
    panelsContract.Service,
    frameContract.Service,
    (() -> plugin.Connection<uiHostContract.Service>?)?
  ) -> (),
  read restore: (Store) -> number,
  read save: (Store) -> (boolean, string?),
  read close: (Store) -> (),
}

local function finite(value: unknown): boolean
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

-- The store validates every loaded entry itself: the versioned reader guarantees only that its values are literals.
local function valid(value: any): panelProperties.PanelProperties?
  if type(value) ~= 'table' then
    return nil
  end
  for key in value do
    if not FIELDS[key] then
      return nil
    end
  end
  if
    not finite(value.curve)
    or not finite(value.curveAxis)
    or type(value.inputLocked) ~= 'boolean'
    or type(value.transformLocked) ~= 'boolean'
  then
    return nil
  end
  return {
    curve = value.curve,
    -- An equivalent angle from a stale or foreign file is rewritten canonically on the next save.
    curveAxis = curved.normalizeAxis(value.curveAxis),
    inputLocked = value.inputLocked,
    transformLocked = value.transformLocked,
  }
end

local function load(report: (string) -> ()): ({ [string]: panelProperties.PanelProperties }, string?)
  local entries: { [string]: panelProperties.PanelProperties } = {}
  local read = versionedFile.read(properties.FILE, properties.VERSION)
  if read.kind == 'missing' then
    return entries, nil
  end
  if read.kind == 'fromTheFuture' then
    local message =
      `panel properties: {properties.FILE} was written by version {read.found}, and this lunette writes version {properties.VERSION}, so it is left alone`
    report(message)
    return entries, message
  end
  if read.kind == 'broken' then
    local message = `panel properties: {properties.FILE} could not be read: {read.message}, so it is left alone`
    report(message)
    return entries, message
  end
  for key, value in read.data do
    local id = panelProperties.decodeId(key)
    local stored = if id then valid(value) else nil
    if stored then
      entries[key] = stored
    else
      report(`{properties.FILE} holds an entry '{tostring(key)}' that is not panel properties, so it is ignored`)
    end
  end
  return entries, nil
end

local function presentationIsWorld(options: uiHostContract.PanelOptions): boolean
  return (options.presentation or 'world') == 'world'
end

function properties.new(source: Source): Store
  local entries, declined = load(source.report)
  local context: plugin.Context? = nil
  local panelService: panelsContract.Service? = nil
  local uiHostService: uiHostContract.Service? = nil
  local currentConnection: plugin.Connection<uiHostContract.Service>? = nil
  local getter: (() -> plugin.Connection<uiHostContract.Service>?)? = nil
  local applying = false
  local nativeEffects: { plugin.Effect } = {}
  local toolkitEffects: { plugin.Effect } = {}

  local writeFile: () -> (boolean, string?)

  local function toolkitId(handle: uiHostContract.Panel): panelProperties.PanelId
    return { kind = 'toolkit', name = handle.name }
  end

  local function nativeId(panel: panelsContract.Panel): panelProperties.PanelId?
    local service = panelService
    if not service then
      return nil
    end
    local key = source.held:key(panel)
    if not key then
      return nil
    end
    local slot = capture.slotOf(source.held, service, panel)
    if not slot then
      return nil
    end
    if panel.kind == 'window' then
      return { kind = 'window', appId = key, slot = slot }
    end
    return { kind = 'monitor', key = key, slot = slot }
  end

  local function recordNative(panel: panelsContract.Panel): ()
    local id = nativeId(panel)
    if not id then
      return
    end
    entries[panelProperties.encodeId(id)] = panelProperties.propertiesOf {
      curve = panel.curve,
      curveAxis = panel.curveAxis,
      inputLocked = panel.locked,
      transformLocked = panel.transformLocked,
    }
    local written, message = writeFile()
    if not written and message then
      source.report(message)
    end
  end

  local function applyNative(panel: panelsContract.Panel, value: panelProperties.PanelProperties): boolean
    local ctx = context
    if not ctx then
      return false
    end
    -- The creator and the store each fill what the other omits.
    local curve = if panel.curveExplicit then panel.curve else value.curve
    local axis = if panel.curveAxisExplicit then panel.curveAxis else value.curveAxis
    if not (panel.curveExplicit and panel.curveAxisExplicit) then
      panel:setCurve(curve, axis, false)
    end
    if not panel.lockedExplicit then
      panel:setLocked(ctx, value.inputLocked)
    end
    if not panel.transformLockedExplicit then
      panel:setTransformLocked(ctx, value.transformLocked)
    end
    return true
  end

  local function restoreNativePanel(panel: panelsContract.Panel): boolean
    local id = nativeId(panel)
    if not id then
      return false
    end
    local value = entries[panelProperties.encodeId(id)]
    if not value then
      return false
    end
    return applyNative(panel, value)
  end

  local function restoreNative(): number
    local service, ctx = panelService, context
    if not service or not ctx then
      return 0
    end
    local restored = 0
    local previous = applying
    applying = true
    for _, panel in ipairs(service:all()) do
      if not panel.dead and restoreNativePanel(panel) then
        restored += 1
      end
    end
    applying = previous
    return restored
  end

  local function toolkitEntry(handle: uiHostContract.Panel): uiHostContract.PanelEntry?
    local service = uiHostService
    if not service then
      return nil
    end
    for _, entry in service:panels() do
      if entry.panel == handle then
        return entry
      end
    end
    return nil
  end

  local function applyToolkit(
    handle: uiHostContract.Panel,
    options: uiHostContract.PanelOptions,
    value: panelProperties.PanelProperties
  ): ()
    -- The creator and the store each fill what the other omits.
    local curve = if options.curve ~= nil then handle:curve() else value.curve
    local axis = if options.curveAxis ~= nil then handle:curveAxis() else value.curveAxis
    if options.curve == nil or options.curveAxis == nil then
      handle:setCurve(curve, axis, false)
    end
    if options.locked == nil then
      handle:setLocked(value.inputLocked, false)
    end
    if options.transformLocked == nil then
      handle:setTransformLocked(value.transformLocked, false)
    end
  end

  local function restoreToolkitPanel(handle: uiHostContract.Panel, options: uiHostContract.PanelOptions): boolean
    if not presentationIsWorld(options) then
      return false
    end
    local value = entries[panelProperties.encodeId(toolkitId(handle))]
    if not value then
      return false
    end
    applyToolkit(handle, options, value)
    return true
  end

  local function restoreToolkit(): number
    local service = uiHostService
    if not service then
      return 0
    end
    local restored = 0
    local previous = applying
    applying = true
    for _, entry in service:panels() do
      if not entry.panel.dead and restoreToolkitPanel(entry.panel, entry.options) then
        restored += 1
      end
    end
    applying = previous
    return restored
  end

  local function recordToolkit(handle: uiHostContract.Panel): ()
    local entry = toolkitEntry(handle)
    if not entry or not presentationIsWorld(entry.options) then
      return
    end
    entries[panelProperties.encodeId(toolkitId(handle))] = handle:properties()
    local written, message = writeFile()
    if not written and message then
      source.report(message)
    end
  end

  local function clear(effects: { plugin.Effect }): ()
    local held = table.clone(effects)
    table.clear(effects)
    for _, effect in ipairs(held) do
      pcall(function(): ()
        effect:dispose()
      end)
    end
  end

  local function subscribeToolkit(connection: plugin.Connection<uiHostContract.Service>): ()
    local service, owner = connection.service, connection.owner
    toolkitEffects[#toolkitEffects + 1] = service:onPanelAdded(owner, {
      run = function(handle: uiHostContract.Panel, options: uiHostContract.PanelOptions): ()
        restoreToolkitPanel(handle, options)
      end,
    })
    toolkitEffects[#toolkitEffects + 1] = service:onPropertiesChanged(owner, {
      run = function(handle: uiHostContract.Panel): ()
        if applying then
          return
        end
        recordToolkit(handle)
      end,
    })
  end

  local function poll(): ()
    local read = getter
    local connection = if read then read() else nil
    if connection == currentConnection then
      return
    end
    clear(toolkitEffects)
    currentConnection = connection
    uiHostService = if connection then connection.service else nil
    if connection then
      subscribeToolkit(connection)
      restoreToolkit()
    end
  end

  -- The arrangement's version 1 and 2 input locks move into the store once per id. A store that cannot take them
  -- refuses the arrangement save, so the old file survives until the locks are written.
  local function migrate(): ()
    local missing = false
    for _, entry in source.loaded do
      if entry.locked ~= nil then
        local id: panelProperties.PanelId = if entry.kind == 'window'
          then { kind = 'window', appId = entry.key, slot = entry.slot }
          else { kind = 'monitor', key = entry.key, slot = entry.slot }
        local key = panelProperties.encodeId(id)
        if entries[key] == nil then
          entries[key] = {
            curve = 0,
            curveAxis = 0,
            inputLocked = entry.locked,
            transformLocked = false,
          }
          missing = true
        end
      end
    end
    if missing then
      local written, message = writeFile()
      if not written then
        local refusal = message
          or `{properties.FILE} could not be written, so the arrangement is left alone until the input locks are saved`
        source.refuse(refusal)
      end
    end
  end

  writeFile = function(): (boolean, string?)
    if declined then
      return false, declined
    end
    local ctx = context
    if not ctx or not ctx:active() then
      return false, 'panel properties: the provider is inactive'
    end
    local ok, failure = pcall(versionedFile.write, properties.FILE, properties.VERSION, entries)
    if not ok then
      return false, `panel properties: {properties.FILE} could not be written: {tostring(failure)}`
    end
    return true, nil
  end

  local function bind(
    _self: Store,
    ctx: plugin.Context,
    service: panelsContract.Service,
    frame: frameContract.Service,
    uiHostGetter: (() -> plugin.Connection<uiHostContract.Service>?)?
  ): ()
    clear(nativeEffects)
    clear(toolkitEffects)
    context, panelService, getter = ctx, service, uiHostGetter
    currentConnection, uiHostService = nil, nil

    nativeEffects[#nativeEffects + 1] = service:onAdded(ctx, {
      run = function(panel: panelsContract.Panel): ()
        local previous = applying
        applying = true
        restoreNativePanel(panel)
        applying = previous
      end,
    })
    local function onNativeChange(panel: panelsContract.Panel): ()
      if applying then
        return
      end
      recordNative(panel)
    end
    nativeEffects[#nativeEffects + 1] = service:onCurveChanged(ctx, { run = onNativeChange })
    nativeEffects[#nativeEffects + 1] = service:onLockChanged(ctx, { run = onNativeChange })
    nativeEffects[#nativeEffects + 1] = service:onTransformLockChanged(ctx, { run = onNativeChange })
    frame:onUpdate(ctx, {
      phase = 'scene',
      order = -150,
      run = function(): ()
        poll()
      end,
    })
    local previous = applying
    applying = true
    migrate()
    restoreNative()
    poll()
    applying = previous
    ctx:effect(function(): () -> ()
      return function(): ()
        clear(nativeEffects)
        clear(toolkitEffects)
        context, panelService, getter = nil, nil, nil
        currentConnection, uiHostService = nil, nil
      end
    end)
  end

  local function restore(_self: Store): number
    return restoreNative() + restoreToolkit()
  end

  local function close(_self: Store): ()
    clear(nativeEffects)
    clear(toolkitEffects)
  end

  return {
    bind = bind,
    restore = restore,
    save = function(_self: Store): (boolean, string?)
      return writeFile()
    end,
    close = close,
  }
end

return properties
