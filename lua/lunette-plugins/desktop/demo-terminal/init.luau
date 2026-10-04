-- The session-global guard prevents another spawn after a source reload.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local logging = require '@lunette-plugins/desktop/logging'

export type Config = {
  read programs: { string }?,
}

export type Settings = {
  read programs: { string },
}

local DEFAULTS: Settings = {
  programs = { 'ghostty', 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' },
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/demo-terminal',
  defaults = DEFAULTS,
  validate = function(settings: Settings, name: string): ()
    for index, program in ipairs(settings.programs) do
      if type(program) ~= 'string' or program == '' then
        error(string.format('plugin %s: option programs[%d] is a non-empty program name', name, index), 0)
      end
    end
  end,
  init = function(context: plugin.Context, settings: Settings): ()
    local attempted: lunette.Process? = nil
    local attempt = 0

    local function spawnNext(): ()
      attempt += 1
      local program = settings.programs[attempt]
      if not program then
        attempted = nil
        logging.report('no terminal emulator was found; start a client with WAYLAND_DISPLAY', 'warn')
        return
      end
      attempted = lunette.spawn { argv = { program } }
    end

    context:on {
      event = lunette.onProcessExited,
      run = function(event: lunette.ProcessExitedEvent)
        if not attempted or event.process.id ~= attempted.id then
          return
        end
        if event.outcome == 'spawnFailed' then
          spawnNext()
        else
          attempted = nil
        end
      end,
    }
    if _G.lunetteDemonstrationSpawned then
      return
    end
    _G.lunetteDemonstrationSpawned = true
    if #settings.programs > 0 and #lunette.windows() == 0 then
      spawnNext()
    end
  end,
}).definition
