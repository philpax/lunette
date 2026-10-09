-- The session-global guard prevents another spawn after a source reload.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local logging = require '@lunette-plugins/desktop/logging'

local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  programs = schema.default(schema.array(schema.string { minLength = 1 })) {
    'ghostty',
    'foot',
    'weston-terminal',
    'alacritty',
    'kitty',
    'xterm',
  },
}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

type SessionGlobals = {
  lunetteDemonstrationSpawned: boolean?,
}

local sessionGlobals = _G :: SessionGlobals

return plugin.consumer<<Config, Settings>> {
  name = 'dev/demo-terminal',
  schema = descriptor,
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
    if sessionGlobals.lunetteDemonstrationSpawned then
      return
    end
    sessionGlobals.lunetteDemonstrationSpawned = true
    if #settings.programs > 0 and #lunette.windows() == 0 then
      spawnNext()
    end
  end,
}
