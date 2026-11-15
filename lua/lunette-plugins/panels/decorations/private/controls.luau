-- The titlebar's content for a native panel: its title, its actions, and its close request.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local curved = require '@lunette-plugins/graphics/curved-surface'

local controls = {}

-- The standard Settings control's controller, structurally. A native panel takes a signed curve and a full axis; its
-- locks are the panel's own state.
export type Lock = {
  read available: boolean,
  read reason: string?,
  read get: () -> boolean,
  read set: (boolean) -> (),
}

export type Bend = {
  read curve: number,
  read axis: number,
  read width: number,
  read height: number,
}

export type Properties = {
  read bend: () -> Bend,
  -- The stored curve and axis, before any clamp, so an untouched Settings popup restores exactly what it found.
  read raw: (() -> { curve: number, axis: number })?,
  read setCurve: (number, number?, boolean?) -> (),
  read axis: boolean,
  read negative: boolean,
  read axisReason: string?,
  read inputLock: Lock,
  read transformLock: Lock,
}

export type Action = {
  read id: string,
  read label: string,
  read enabled: boolean,
  read run: () -> (),
}

export type Options = {
  read title: string,
  read actions: { Action },
  read close: () -> (),
  -- The Settings controller for the native panel, or nil for a titlebar that offers no Settings control.
  read properties: Properties?,
}

function controls.options(context: plugin.Context, panel: panels.Panel, refusal: string?, select: () -> ()): Options
  local actions: { Action } = {}
  local named = if panel.kind == 'window'
    then (panel.source :: lunette.Window).title
    else (panel.source :: lunette.Monitor).name
  local title = panel.title or named or ''
  if panel.kind == 'monitor' then
    local monitor: lunette.Monitor = panel.source :: lunette.Monitor
    table.insert(actions, {
      id = 'restart',
      label = 'Restart mirror',
      enabled = true,
      run = function(): ()
        if context:active() and not panel.dead and not monitor.dead then
          monitor:dismiss()
          if not monitor:mirror() then
            error('monitor capture: restart was refused for ' .. monitor.name, 0)
          end
        end
      end,
    })
    if not monitor.directCapture then
      local state = lunette.monitorSelection()
      local label = if state.state == 'pending'
        then 'Waiting for permission'
        else if state.state == 'failed' then 'Retry selection' else 'Select monitors'
      local message = state.message or refusal
      if message and state.state ~= 'pending' then
        label ..= ': ' .. message
      end
      table.insert(actions, { id = 'select', label = label, enabled = state.state ~= 'pending', run = select })
    end
  end
  local properties: Properties = {
    bend = function(): Bend
      local width, height = panel.width, panel.height
      -- The read-out derives its degrees from the same across-axis extent the panel bends over.
      return {
        curve = curved.curvature(width, height, panel.curve, panel.curveAxis),
        axis = panel.curveAxis,
        width = width,
        height = height,
      }
    end,
    raw = function(): { curve: number, axis: number }
      return { curve = panel.curve, axis = panel.curveAxis }
    end,
    setCurve = function(curve: number, axis: number?, commit: boolean?): ()
      if context:active() and not panel.dead and not panel.source.dead then
        panel:setCurve(curve, axis, commit == true)
      end
    end,
    axis = true,
    negative = true,
    axisReason = nil,
    inputLock = {
      available = true,
      reason = nil,
      get = function(): boolean
        return panel.locked
      end,
      set = function(value: boolean): ()
        if context:active() and not panel.dead and not panel.source.dead then
          panel:setLocked(context, value)
        end
      end,
    },
    transformLock = {
      available = true,
      reason = nil,
      get = function(): boolean
        return panel.transformLocked
      end,
      set = function(value: boolean): ()
        if context:active() and not panel.dead and not panel.source.dead then
          panel:setTransformLocked(context, value)
        end
      end,
    },
  }
  return {
    title = if panel.locked then title .. ' [locked]' else title,
    actions = actions,
    close = function(): ()
      if context:active() and not panel.dead and not panel.source.dead and not panel:close(context) then
        error('panel close: request was refused for ' .. tostring(panel.source.id), 0)
      end
    end,
    properties = properties,
  }
end

-- For the same context and target, callbacks read live handles and methods; selection shares the refusal state.
-- Only the title and ordered action fields affect rendering.
function controls.sameContent(first: Options, second: Options): boolean
  if first.title ~= second.title or #first.actions ~= #second.actions then
    return false
  end
  for index, action in first.actions do
    local other = second.actions[index]
    if action.id ~= other.id or action.label ~= other.label or action.enabled ~= other.enabled then
      return false
    end
  end
  return true
end

return controls
