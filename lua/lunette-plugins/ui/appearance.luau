-- Replaces a panel's appearance only after every exact font acquisition succeeds.
local ui = require '@lunette-contracts/ui'
local globalTheme = require '@lunette-contracts/theme'
local records = require './panel-state'
local theme = require './theme'
local input = require './input'
local draw = require './draw'

local appearance = {}

local function disposeAll(leases: { globalTheme.FontLease }, failures: { string }): ()
  for _, lease in leases do
    local ok, failure = pcall(lease.dispose, lease)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
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
  local radiusX = snapshot.theme.radii.uiPanel * panel.logicalWidth / (panel.width * math.abs(sx))
  local radiusY = snapshot.theme.radii.uiPanel * panel.logicalHeight / (panel.height * math.abs(sy))
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
  end)
  if not ok then
    panel.refreshing = false
    local failures = { tostring(failure) }
    disposeAll(acquired, failures)
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
  local old: { globalTheme.FontLease } = { panel.lease }
  local affected: { records.Control } = {}
  for _, current in prepared do
    if theme.geometryChanged(current.record.theme, current.value) then
      affected[#affected + 1] = current.record
    end
    old[#old + 1] = current.record.lease
  end
  if panel.theme.font ~= (value :: ui.Theme).font then
    draw.clearCache(panel.measurements)
  end
  panel.spec, panel.theme, panel.lease = spec, value :: ui.Theme, lease :: globalTheme.FontLease
  panel.themeRevision, panel.radiusX, panel.radiusY = snapshot.revision, radiusX, radiusY
  for _, current in prepared do
    if current.record.theme.font ~= current.value.font then
      draw.clearCache(current.record.measurements)
      if current.record.widget.clearMeasurements then
        current.record.widget.clearMeasurements()
      end
    end
    current.record.spec, current.record.theme, current.record.lease = current.spec, current.value, current.lease
  end
  panel.revision += 1
  local failures: { string } = {}
  local terminals: { () -> () } = {}
  local completed, problem = pcall(function(): ()
    for _, current in affected do
      terminals[#terminals + 1] = input.prepareCancel(panel, current, 'control-removed')
    end
    for _, terminal in terminals do
      local cancelled, failure = pcall(terminal)
      if not cancelled then
        failures[#failures + 1] = tostring(failure)
      end
    end
  end)
  if not completed then
    failures[#failures + 1] = tostring(problem)
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
  local prepared, value = pcall(theme.materialize, spec, lease.font)
  if not prepared then
    local failures = { tostring(value) }
    disposeAll({ lease }, failures)
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
  local old = record.lease
  local changed = theme.geometryChanged(record.theme, value)
  if record.theme.font ~= value.font then
    draw.clearCache(record.measurements)
    if record.widget.clearMeasurements then
      record.widget.clearMeasurements()
    end
  end
  record.overrides, record.spec, record.theme, record.lease = copied, spec, value, lease
  panel.revision += 1
  local ok, failure = pcall(function(): ()
    if changed then
      input.cancel(panel, record, 'control-removed')
    end
  end)
  local failures: { string } = if ok then {} else { tostring(failure) }
  disposeAll({ old }, failures)
  if #failures > 0 then
    error('ui appearance: ' .. table.concat(failures, '; '), 0)
  end
end

return appearance
