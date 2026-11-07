-- Owns bounded capture observation and exports after manual or automatic completion.
local plugin = require '@lunette-plugin'
local capture = require './capture'

local controller = {}

export type Options = {
  read capacity: number,
  read duration: number,
  read observe: ((capture.Record) -> ()) -> () -> (),
  read export: (string) -> (),
  read changed: (() -> ())?,
}
export type Status = 'idle' | 'capturing' | 'pending'
export type Controller = {
  read toggle: (Controller) -> (),
  read status: (Controller) -> Status,
}

function controller.new(context: plugin.Context, options: Options): Controller
  local pending: capture.State? = nil
  local observation: plugin.Effect? = nil
  local function changed(): ()
    if options.changed then
      options.changed()
    end
  end
  local function release(): ()
    local held = observation
    observation = nil
    if held then
      held:dispose()
    end
  end
  local function export(): ()
    release()
    changed()
    options.export(capture.csv(assert(pending)))
    pending = nil
    changed()
  end
  local function start(): ()
    local state = capture.new(options.capacity, options.duration)
    pending = state
    local ok, result = pcall(function(): plugin.Effect
      return context:on {
        event = options.observe,
        run = function(record: capture.Record): ()
          local observed, message = pcall(capture.observe, state, record)
          if not observed then
            release()
            capture.cancel(state)
            pending = nil
            changed()
            error(message, 0)
          end
          if state.status ~= 'capturing' then
            export()
          end
        end,
      }
    end)
    if not ok then
      pending = nil
      changed()
      error(result, 0)
    end
    observation = result
    changed()
  end
  return {
    toggle = function(): ()
      if pending then
        capture.stop(pending)
        export()
      else
        start()
      end
    end,
    status = function(): Status
      return if not pending then 'idle' elseif pending.status == 'capturing' then 'capturing' else 'pending'
    end,
  }
end

return controller
