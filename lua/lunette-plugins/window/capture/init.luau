-- Lists native windows in the wrist menu and controls their captures.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local menu = require '@lunette-contracts/menu'
local logging = require '@lunette-plugins/diagnostics/desktop-logging'

type Empty = {}

return plugin.consumer<<Empty, Empty>> {
  name = 'desktop/window-capture',
  requires = { menu.capability },
  init = function(context: plugin.Context, _settings: Empty): ()
    local choices = lunette.captureWindows()
    if choices == nil then
      return
    end
    local service: menu.Service = context:require(menu.capability)
    local registrations: { [string]: menu.Registration } = {}
    local function setRow(windowId: number, label: string, captured: boolean): ()
      local id = 'desktop/window-capture/' .. tostring(windowId)
      local previous = registrations[id]
      if previous then
        previous:dispose()
      end
      registrations[id] = service:register(context, {
        id = id,
        label = if captured then 'Stop sharing ' .. label else label,
        group = 'Windows',
        selected = captured,
        run = function(): ()
          if not context:active() then
            return
          end
          local ok = if captured then lunette.stopCaptureWindow(windowId) else lunette.captureWindow(windowId)
          if not ok then
            logging.report('Window sharing could not change. Refresh the window list and try again.', 'warn')
            return
          end
          setRow(windowId, label, not captured)
        end,
      })
    end
    local function populate(windows: { lunette.CaptureWindow }): ()
      for _, row in registrations do
        row:dispose()
      end
      table.clear(registrations)
      local titles: { [string]: number } = {}
      for _, window in windows do
        titles[window.title] = (titles[window.title] or 0) + 1
      end
      for _, window in windows do
        local label = if titles[window.title] > 1 then window.title .. ' (' .. tostring(window.id) .. ')' else window.title
        setRow(window.id, label, window.captured)
      end
      if #windows == 0 then
        registrations.empty = service:register(context, {
          id = 'desktop/window-capture/empty',
          label = 'No windows available',
          group = 'Windows',
          enabled = false,
          run = function() end,
        })
      end
    end
    local function refresh(): ()
      if context:active() then
        local windows = lunette.captureWindows()
        if windows then
          populate(windows)
        end
      end
    end
    service:register(context, {
      id = 'desktop/window-capture/refresh',
      label = 'Refresh window list',
      group = 'Windows',
      run = refresh,
    })
    context:on {
      event = lunette.onWindowClosed,
      run = function(_event: lunette.WindowClosedEvent): ()
        refresh()
      end,
    }
    populate(choices)
  end,
}
