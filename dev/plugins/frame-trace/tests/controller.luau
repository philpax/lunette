local testing = require '@testing'
local plugin = require '@lunette-plugin'
local controller = require '../private/controller'
local capture = require '../private/capture'
local expect = testing.expect
local test = testing.suite()

type Fixture = {
  state: controller.Controller,
  emit: (capture.Record) -> (),
  cancelled: () -> number,
  exported: () -> string?,
  reload: () -> (),
}

local function fixture(capacity: number?): Fixture
  local callback: ((capture.Record) -> ())? = nil
  local cancelled = 0
  local exported: string? = nil
  local cleanup: (() -> ())? = nil
  local context = {
    on = function(
      _self: plugin.Context,
      subscription: {
        event: ((capture.Record) -> ()) -> () -> (),
        run: (capture.Record) -> (),
      }
    ): plugin.Effect
      local cancel = subscription.event(subscription.run)
      local held = true
      cleanup = function(): ()
        if held then
          held = false
          cancel()
        end
      end
      return { dispose = cleanup }
    end,
  }
  local state = controller.new(context, {
    capacity = capacity or 4,
    duration = 10,
    observe = function(run: (capture.Record) -> ()): () -> ()
      expect.equal(callback, nil, 'only one observer is active')
      callback = run
      return function(): ()
        callback = nil
        cancelled += 1
      end
    end,
    export = function(contents: string): ()
      expect.equal(callback, nil, 'export runs after observation ends')
      exported = contents
    end,
  })
  return {
    state = state,
    emit = function(row: capture.Record): ()
      assert(callback)(row)
    end,
    cancelled = function(): number
      return cancelled
    end,
    exported = function(): string?
      return exported
    end,
    reload = function(): ()
      assert(cleanup)()
    end,
  }
end

test('completion releases observation and makes a bounded export available', function()
  local fixture = fixture(1)
  fixture.state:start()
  fixture.emit { sequence = 1, syncTime = 0, active = true, visible = true, focused = false }
  expect.equal(fixture.state:status(), 'complete')
  expect.equal(fixture.cancelled(), 1)
  fixture.state:export()
  expect.truthy(assert(fixture.exported()):find('1,1,0', 1, true))
end)

test('stop preserves rows, cancel releases and discards them, and starting again is safe', function()
  local fixture = fixture()
  fixture.state:start()
  fixture.emit { sequence = 1, syncTime = 0 }
  fixture.state:stop()
  expect.equal(fixture.cancelled(), 1)
  fixture.state:export()
  fixture.state:start()
  fixture.state:cancel()
  expect.equal(fixture.cancelled(), 2)
  expect.equal(fixture.state:status(), 'idle')
  expect.raises(function()
    fixture.state:export()
  end, 'no completed capture')
end)

test('a malformed observer record releases capture before reporting the error', function()
  local fixture = fixture()
  fixture.state:start()
  expect.raises(function()
    fixture.emit { sequence = 1, syncTime = 0, draw = math.huge }
  end, 'draw')
  expect.equal(fixture.cancelled(), 1)
  expect.equal(fixture.state:status(), 'idle')
end)

test('source reload releases observation through the context effect', function()
  local fixture = fixture()
  fixture.state:start()
  fixture.reload()
  expect.equal(fixture.cancelled(), 1)
end)

return test
