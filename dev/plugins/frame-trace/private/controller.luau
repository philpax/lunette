-- Owns capture observation and releases it before stop, cancel, export, and error propagation.
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
export type Controller = {
  read start: (Controller) -> (),
  read stop: (Controller) -> (),
  read cancel: (Controller) -> (),
  read export: (Controller) -> (),
  read status: (Controller) -> string,
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
  return {
    start = function(): ()
      assert(observation == nil, 'frame trace: capture is already active')
      local state = capture.new(options.capacity, options.duration)
      pending = state
      observation = context:on {
        event = options.observe,
        run = function(record: capture.Record): ()
          local ok, message = pcall(capture.observe, state, record)
          if not ok then
            release()
            capture.cancel(state)
            pending = nil
            changed()
            error(message, 0)
          end
          if state.status ~= 'capturing' then
            release()
            changed()
          end
        end,
      }
      changed()
    end,
    stop = function(): ()
      release()
      if pending then
        capture.stop(pending)
      end
      changed()
    end,
    cancel = function(): ()
      release()
      if pending then
        capture.cancel(pending)
      end
      pending = nil
      changed()
    end,
    export = function(): ()
      assert(observation == nil and pending ~= nil, 'frame trace: no completed capture to export')
      options.export(capture.csv(assert(pending)))
    end,
    status = function(): string
      return if pending then pending.status else 'idle'
    end,
  }
end

return controller
