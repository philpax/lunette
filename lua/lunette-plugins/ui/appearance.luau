-- Replaces a panel's appearance only after every control's appearance is resolved.
local ui = require '@lunette-contracts/ui'
local globalTheme = require '@lunette-contracts/theme'
local records = require './panel-state'
local theme = require './theme'
local input = require './input'
local draw = require './draw'
local cleanup = require './cleanup'

local appearance = {}

-- Panel radii are logical pixels that keep the theme's world-space corner radius under the panel's scale.
function appearance.radii(snapshot: globalTheme.Snapshot, panel: records.Panel): (number, number)
  local sx, sy = panel.pose:getScale()
  local radius = snapshot.theme.radii.uiPanel
  return radius * panel.logicalWidth / (panel.width * math.abs(sx)),
    radius * panel.logicalHeight / (panel.height * math.abs(sy))
end

local function stableRadius(value: number, previous: number): number
  -- Float matrix decomposition perturbs scale during rigid rotation.
  return if math.abs(value - previous) <= 1e-6 * math.max(value, previous) then previous else value
end

local function clearControl(record: records.Control): ()
  draw.clearCache(record.measurements)
  local clear = record.widget.clearMeasurements
  if clear then
    clear()
  end
end

function appearance.refresh(panel: records.Panel, force: boolean?): ()
  if panel.dead or panel.cancelling or not panel.context:active() or not panel.context:owns(panel.owner) then
    return
  end
  local snapshot = panel.themes:current()
  local sameTheme = snapshot.revision == panel.themeRevision
  local radiusX, radiusY = appearance.radii(snapshot, panel)
  if sameTheme then
    radiusX = stableRadius(radiusX, panel.radiusX)
    radiusY = stableRadius(radiusY, panel.radiusY)
    if not force and radiusX == panel.radiusX and radiusY == panel.radiusY then
      return
    end
  end
  local spec = theme.inherit(theme.inherit(theme.global(snapshot.theme, radiusX), panel.providerTheme), panel.overrides)
  local value = theme.materialize(spec, panel.themes:font(spec.font))
  type Resolved = { record: records.Control, spec: ui.ThemeOverrides, value: ui.Theme }
  local resolved: { Resolved } = {}
  for _, record in panel.controls do
    if not record.dead then
      local controlSpec = theme.inherit(spec, record.overrides)
      resolved[#resolved + 1] = {
        record = record,
        spec = controlSpec,
        value = theme.materialize(controlSpec, panel.themes:font(controlSpec.font)),
      }
    end
  end
  local inheritedRadius = (panel.overrides == nil or panel.overrides.panelRadius == nil)
    and panel.providerTheme.panelRadius == nil
  local scaleChanged = inheritedRadius and (radiusX ~= panel.radiusX or radiusY ~= panel.radiusY)
  local panelChanged = scaleChanged or theme.geometryChanged(panel.theme, value)
  local affected: { records.Control } = {}
  for _, current in resolved do
    if scaleChanged or theme.geometryChanged(current.record.theme, current.value) then
      affected[#affected + 1] = current.record
    end
    current.record.spec, current.record.theme = current.spec, current.value
  end
  panel.spec, panel.theme = spec, value
  panel.themeRevision, panel.radiusX, panel.radiusY = snapshot.revision, radiusX, radiusY
  panel.revision += 1
  local operations: { () -> () } = {}
  if panelChanged then
    operations[#operations + 1] = function(): ()
      draw.clearCache(panel.measurements)
    end
  end
  for _, record in affected do
    operations[#operations + 1] = function(): ()
      clearControl(record)
      input.cancel(panel, record, 'control-removed')
    end
  end
  cleanup.run('ui appearance', operations)
end

function appearance.control(panel: records.Panel, record: records.Control, overrides: ui.ThemeOverrides?): ()
  panel.refresh()
  local copied = theme.copyOverrides(overrides)
  local spec = theme.inherit(panel.spec, copied)
  local value = theme.materialize(spec, panel.themes:font(spec.font))
  local changed = theme.geometryChanged(record.theme, value)
  record.overrides, record.spec, record.theme = copied, spec, value
  panel.revision += 1
  if changed then
    clearControl(record)
    input.cancel(panel, record, 'control-removed')
  end
end

return appearance
