-- The titlebar's content for a native panel: its title, its actions, and its close request.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'

local controls = {}

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
  return {
    title = title,
    actions = actions,
    close = function(): ()
      if context:active() and not panel.dead and not panel.source.dead and not panel:close(context) then
        error('panel close: request was refused for ' .. tostring(panel.source.id), 0)
      end
    end,
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
