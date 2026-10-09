-- Replaces a panel's appearance only after every exact font acquisition succeeds.
local ui = require '@lunette-contracts/ui'
local globalTheme = require '@lunette-contracts/theme'
local records = require './panel-state'
local theme = require './theme'
local input = require './input'
local draw = require './draw'

local appearance = {}

local function stableRadius(value: number, previous: number): number
  -- Float matrix decomposition perturbs scale during rigid rotation.
  return if math.abs(value - previous) <= 1e-6 * math.max(value, previous) then previous else value
end

local function attempt(label: string, run: () -> (), failures: { string }): ()
  local ok, failure = pcall(run)
  if not ok then
    failures[#failures + 1] = label .. ': ' .. tostring(failure)
  end
end

local function disposeAll(leases: { globalTheme.FontLease }, failures: { string }): ()
  for index, lease in leases do
    attempt('font lease ' .. tostring(index) .. ' cleanup', function(): ()
      lease:dispose()
    end, failures)
  end
end

local function clearControl(record: records.Control, failures: { string }): ()
  attempt('control ' .. record.id .. ' draw cache cleanup', function(): ()
    draw.clearCache(record.measurements)
  end, failures)
  if record.widget.clearMeasurements then
    attempt('control ' .. record.id .. ' text measurements cleanup', record.widget.clearMeasurements, failures)
  end
end

function appearance.refresh(panel: records.Panel, force: boolean?): ()
  if
    panel.dead
    or panel.cancelling
    or panel.refreshing
    or not panel.context:active()
    or not panel.context:owns(panel.owner)
  then
    return
  end
  local snapshot = panel.themes:current()
  local sx, sy = panel.pose:getScale()
  local measuredX = snapshot.theme.radii.uiPanel * panel.logicalWidth / (panel.width * math.abs(sx))
  local measuredY = snapshot.theme.radii.uiPanel * panel.logicalHeight / (panel.height * math.abs(sy))
  local radiusX = if snapshot.revision == panel.themeRevision then stableRadius(measuredX, panel.radiusX) else measuredX
  local radiusY = if snapshot.revision == panel.themeRevision then stableRadius(measuredY, panel.radiusY) else measuredY
  if
    not force
    and snapshot.revision == panel.themeRevision
    and radiusX == panel.radiusX
    and radiusY == panel.radiusY
  then
    return
  end
  local provider = theme.inherit(theme.global(snapshot.theme, radiusX), panel.providerTheme)
  local spec = theme.inherit(provider, panel.overrides)
  local acquired: { globalTheme.FontLease } = {}
  type Prepared = { record: records.Control, spec: ui.ThemeOverrides, lease: globalTheme.FontLease, value: ui.Theme }
  local prepared: { Prepared } = {}
  local lease: globalTheme.FontLease? = nil
  local value: ui.Theme? = nil
  local old: { globalTheme.FontLease } = { panel.lease }
  local affected: { records.Control } = {}
  local failures: { string } = {}
  panel.refreshing = true
  local ok, failure = pcall(function(): ()
    lease = panel.themes:acquireFont(panel.context, spec.font)
    acquired[#acquired + 1] = lease :: globalTheme.FontLease
    value = theme.materialize(spec, (lease :: globalTheme.FontLease).font)
    for _, record in panel.controls do
      if not record.dead then
        local controlSpec = theme.inherit(spec, record.overrides)
        local controlLease = panel.themes:acquireFont(panel.context, controlSpec.font)
        acquired[#acquired + 1] = controlLease
        prepared[#prepared + 1] = {
          record = record,
          spec = controlSpec,
          lease = controlLease,
          value = theme.materialize(controlSpec, controlLease.font),
        }
      end
    end
    local inheritedRadius = panel.overrides == nil or panel.overrides.panelRadius == nil
    local scaleChanged = inheritedRadius
      and panel.providerTheme.panelRadius == nil
      and (radiusX ~= panel.radiusX or radiusY ~= panel.radiusY)
    for _, current in prepared do
      if scaleChanged or theme.geometryChanged(current.record.theme, current.value) then
        affected[#affected + 1] = current.record
      end
      old[#old + 1] = current.record.lease
    end
    if theme.geometryChanged(panel.theme, value :: ui.Theme) or scaleChanged then
      attempt('panel draw cache cleanup', function(): ()
        draw.clearCache(panel.measurements)
      end, failures)
    end
    for _, current in affected do
      clearControl(current, failures)
    end
  end)
  if not ok then
    failures[#failures + 1] = 'prepare refresh: ' .. tostring(failure)
  end
  if #failures > 0 then
    disposeAll(acquired, failures)
    panel.refreshing = false
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
  panel.spec, panel.theme, panel.lease = spec, value :: ui.Theme, lease :: globalTheme.FontLease
  panel.themeRevision, panel.radiusX, panel.radiusY = snapshot.revision, radiusX, radiusY
  for _, current in prepared do
    current.record.spec, current.record.theme, current.record.lease = current.spec, current.value, current.lease
  end
  panel.revision += 1
  local terminals: { () -> () } = {}
  for _, current in affected do
    attempt('control ' .. current.id .. ' prepare cancellation', function(): ()
      terminals[#terminals + 1] = input.prepareCancel(panel, current, 'control-removed')
    end, failures)
  end
  for index, terminal in terminals do
    attempt('cancellation ' .. tostring(index), terminal, failures)
  end
  disposeAll(old, failures)
  panel.refreshing = false
  if #failures > 0 then
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
end

function appearance.control(panel: records.Panel, record: records.Control, overrides: ui.ThemeOverrides?): ()
  panel.refresh()
  local copied = theme.copyOverrides(overrides)
  local spec = theme.inherit(panel.spec, copied)
  local lease = panel.themes:acquireFont(panel.context, spec.font)
  local value: ui.Theme? = nil
  local changed = false
  local failures: { string } = {}
  attempt('control ' .. record.id .. ' prepare appearance', function(): ()
    value = theme.materialize(spec, lease.font)
    changed = theme.geometryChanged(record.theme, value :: ui.Theme)
    if changed then
      clearControl(record, failures)
    end
  end, failures)
  if #failures > 0 then
    disposeAll({ lease }, failures)
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
  local old = record.lease
  record.overrides, record.spec, record.theme, record.lease = copied, spec, value :: ui.Theme, lease
  panel.revision += 1
  if changed then
    attempt('control ' .. record.id .. ' cancellation', function(): ()
      input.cancel(panel, record, 'control-removed')
    end, failures)
  end
  disposeAll({ old }, failures)
  if #failures > 0 then
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
end

return appearance
