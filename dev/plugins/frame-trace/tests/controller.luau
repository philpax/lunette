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
  exports: { string },
  failExport: (boolean) -> (),
  failObserve: (boolean) -> (),
  reload: () -> (),
}

local function fixture(capacity: number?, duration: number?): Fixture
  local callback: ((capture.Record) -> ())? = nil
  local cancelled = 0
  local exports: { string } = {}
  local exportFails, observeFails = false, false
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
    duration = duration or 10,
    observe = function(run: (capture.Record) -> ()): () -> ()
      assert(not observeFails, 'observer unavailable')
      expect.equal(callback, nil, 'only one observer is active')
      callback = run
      return function(): ()
        callback = nil
        cancelled += 1
      end
    end,
    export = function(contents: string): ()
      expect.equal(callback, nil, 'export runs after observation ends')
      assert(not exportFails, 'save unavailable')
      table.insert(exports, contents)
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
    exports = exports,
    failExport = function(failed: boolean): ()
      exportFails = failed
    end,
    failObserve = function(failed: boolean): ()
      observeFails = failed
    end,
    reload = function(): ()
      assert(cleanup)()
    end,
  }
end

test('the toggle stops observation and immediately exports the recorded rows', function()
  local fixture = fixture()
  expect.equal(fixture.state:status(), 'idle')
  fixture.state:toggle()
  expect.equal(fixture.state:status(), 'capturing')
  fixture.emit { sequence = 1, syncTime = 0 }
  expect.equal(#fixture.exports, 0, 'capture does not export while active')
  fixture.state:toggle()
  expect.equal(fixture.cancelled(), 1)
  expect.equal(fixture.state:status(), 'idle')
  expect.equal(#fixture.exports, 1)
  expect.truthy(fixture.exports[1]:find('1,1,0', 1, true))
  fixture.state:toggle()
  expect.equal(fixture.state:status(), 'capturing', 'the next activation starts a fresh capture')
  fixture.reload()
end)

test('capacity and duration completion each release observation and export exactly once', function()
  for _, options in { { capacity = 1, duration = 10 }, { capacity = 4, duration = 0.1 } } do
    local fixture = fixture(options.capacity, options.duration)
    fixture.state:toggle()
    fixture.emit { sequence = 1, syncTime = 0, active = true, visible = true, focused = false }
    if options.capacity > 1 then
      expect.equal(#fixture.exports, 0)
      fixture.emit { sequence = 2, syncTime = 0.1 }
    end
    expect.equal(fixture.state:status(), 'idle')
    expect.equal(fixture.cancelled(), 1)
    expect.equal(#fixture.exports, 1)
    expect.truthy(fixture.exports[1]:find('1,1,0', 1, true))
    fixture.reload()
    expect.equal(fixture.cancelled(), 1, 'completion already released the context effect')
    expect.equal(#fixture.exports, 1, 'shutdown does not repeat an export')
  end
end)

test('stopping before the first record exports only the CSV header', function()
  local fixture = fixture()
  fixture.state:toggle()
  fixture.state:toggle()
  expect.equal(fixture.cancelled(), 1)
  expect.equal(fixture.state:status(), 'idle')
  expect.equal(#fixture.exports, 1)
  expect.truthy(fixture.exports[1]:match '^formatVersion,sequence,syncTime,[^\n]+\n$')
end)

test('a failed manual or automatic export retains rows for a retry through the same toggle', function()
  for _, capacity in { 1, 4 } do
    local fixture = fixture(capacity)
    fixture.state:toggle()
    fixture.failExport(true)
    expect.raises(function()
      fixture.emit { sequence = 7, syncTime = 2 }
      fixture.state:toggle()
    end, 'save unavailable')
    expect.equal(fixture.cancelled(), 1)
    expect.equal(fixture.state:status(), 'pending')
    expect.equal(#fixture.exports, 0)
    expect.raises(function()
      fixture.state:toggle()
    end, 'save unavailable')
    expect.equal(fixture.state:status(), 'pending')
    fixture.failExport(false)
    fixture.state:toggle()
    expect.equal(fixture.state:status(), 'idle')
    expect.equal(#fixture.exports, 1)
    expect.truthy(fixture.exports[1]:find('1,7,2', 1, true))
    fixture.state:toggle()
    expect.equal(fixture.state:status(), 'capturing')
    fixture.reload()
  end
end)

test('a malformed observer record releases capture before reporting the error', function()
  local fixture = fixture()
  fixture.state:toggle()
  expect.raises(function()
    fixture.emit { sequence = 1, syncTime = 0, draw = math.huge }
  end, 'draw')
  expect.equal(fixture.cancelled(), 1)
  expect.equal(fixture.state:status(), 'idle')
  expect.equal(#fixture.exports, 0)
  fixture.state:toggle()
  expect.equal(fixture.state:status(), 'capturing')
  fixture.reload()
end)

test('an observation registration error leaves the toggle ready to start again', function()
  local fixture = fixture()
  fixture.failObserve(true)
  expect.raises(function()
    fixture.state:toggle()
  end, 'observer unavailable')
  expect.equal(fixture.state:status(), 'idle')
  fixture.failObserve(false)
  fixture.state:toggle()
  expect.equal(fixture.state:status(), 'capturing')
  fixture.reload()
end)

test('source reload releases observation without exporting an unfinished capture', function()
  local fixture = fixture()
  fixture.state:toggle()
  fixture.emit { sequence = 1, syncTime = 0 }
  fixture.reload()
  expect.equal(fixture.cancelled(), 1)
  expect.equal(#fixture.exports, 0)
end)

return test
