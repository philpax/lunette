-- Supplies native close and monitor recovery actions to the shared titlebar.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'
local ui = require '@lunette-contracts/ui'

local controls = {}

function controls.options(
  context: plugin.Context,
  given: panels.Panel,
  style: ui.TitlebarStyleOverrides?,
  refusal: string?,
  select: () -> ()
): ui.TitlebarOptions
  local panel: panels.Panel = given
  local identity = panel.kind .. '/' .. panel.source.id
  local actions: { ui.TitlebarAction } = {}
  local title = panel.title or ''
  if panel.kind == 'window' then
    local window: lunette.Window = panel.source :: lunette.Window
    title = panel.title or window.title or ''
  end
  if panel.kind == 'monitor' then
    local monitor: lunette.Monitor = panel.source :: lunette.Monitor
    title = panel.title or monitor.name
    actions[#actions + 1] = {
      id = 'restart/' .. identity,
      label = 'Restart mirror',
      width = 3,
      run = function(): ()
        if context:active() and not panel.dead and not monitor.dead then
          monitor:dismiss()
          if not monitor:mirror() then
            error('monitor capture: restart was refused for ' .. monitor.name, 0)
          end
        end
      end,
    }
    if not monitor.directCapture then
      local state = lunette.monitorSelection()
      local label = if state.state == 'pending'
        then 'Waiting for permission'
        else if state.state == 'failed' then 'Retry selection' else 'Select monitors'
      local message = state.message or refusal
      if message and state.state ~= 'pending' then
        label ..= ': ' .. message
      end
      actions[#actions + 1] = {
        id = 'select/' .. identity,
        label = label,
        width = 4,
        enabled = state.state ~= 'pending',
        run = select,
      }
    end
  end
  return {
    title = title,
    style = style,
    closeId = 'close/' .. identity,
    onClose = function(): ()
      if context:active() and not panel.dead and not panel.source.dead and not panel:close(context) then
        error('panel close: request was refused for ' .. tostring(panel.source.id), 0)
      end
    end,
    actions = actions,
  }
end

return controls
