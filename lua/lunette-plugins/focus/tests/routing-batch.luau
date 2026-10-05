-- Physical event batches bind committed text to the route visible before key binding handlers run.
local testing = require '@testing'
local sourceModule = require '../source'
local expect = testing.expect
local test = testing.suite()

local function fixture(key)
  local fake = testing.native()
  local texts, listeners = {}, {}
  local receiver = {
    key = key or function()
      return false
    end,
    text = function(value)
      texts[#texts + 1] = value
      return true
    end,
  }
  local snapshot =
    { handle = { dead = false }, target = { kind = 'local', receiver = receiver, wantsKeyboard = true }, revision = 1 }
  local route = {
    snapshot = function()
      return snapshot
    end,
    reconcile = function()
      error 'local input must not reconcile native override'
    end,
    keymapSeat = function()
      error 'physical key must not translate'
    end,
    listen = function(run)
      listeners[#listeners + 1] = run
      return function()
        table.remove(listeners, table.find(listeners, run))
      end
    end,
  }
  local source, inverse = sourceModule.new({
    owns = function()
      return true
    end,
  }, {}, { mode = 'physical' }, route)
  local function change()
    snapshot = {
      handle = { dead = false },
      target = { kind = 'local', receiver = receiver, wantsKeyboard = true },
      revision = snapshot.revision + 1,
    }
    for _, run in table.clone(listeners) do
      run()
    end
  end
  return { source = source, inverse = inverse, texts = texts, change = change, reports = fake.events.reported }
end

test('beginBatch binds text before a binding changes the focused route', function()
  local f = fixture()
  f.source:beginBatch(1)
  f.change()
  expect.equal(f.source:text('stale', 1).kind, 'refused', 'text after binding route change')
  expect.equal(#f.texts, 0, 'replacement route receives no stale text')
  f.source:beginBatch(2)
  expect.equal(f.source:text('current', 2).kind, 'consumed', 'the next batch')
  expect.equal(f.texts[1], 'current', 'only current batch text')
  f.inverse()
end)

test('a consumed local physical key poisons all text until the next batch', function()
  local f = fixture(function()
    return true
  end)
  f.source:beginBatch(4)
  expect.equal(f.source:key({ code = 30, batch = 4 }).kind, 'consumed', 'the binding consumes its key')
  expect.equal(f.source:text('a', 4).kind, 'refused', 'matching text')
  expect.equal(f.source:text('b', 4).kind, 'refused', 'later text in the same batch')
  f.source:beginBatch(5)
  expect.equal(f.source:text('c', 5).kind, 'consumed', 'fresh batch text')
  expect.equal(table.concat(f.texts, ','), 'c', 'no consumed-key duplicates')
  f.inverse()
end)

test('a failed local physical key poisons text but not a later batch', function()
  local f = fixture(function()
    error 'physical receiver failure'
  end)
  f.source:beginBatch(7)
  expect.equal(f.source:key({ code = 30, batch = 7 }).kind, 'failed', 'receiver failure')
  expect.equal(f.source:text('a', 7).kind, 'refused', 'failed-key text')
  f.source:beginBatch(8)
  expect.equal(f.source:text('b', 8).kind, 'consumed', 'new batch text')
  expect.equal(#f.reports, 1, 'receiver failure is reported')
  f.inverse()
end)

test('unhandled local physical keys leave valid committed text deliverable', function()
  local f = fixture()
  f.source:beginBatch(10)
  expect.equal(f.source:key({ code = 30, batch = 10 }).kind, 'unhandled', 'unhandled physical key')
  expect.equal(f.source:text('é🙂', 10).kind, 'consumed', 'committed text')
  expect.equal(f.texts[1], 'é🙂', 'full committed string')
  f.inverse()
end)

test('old and missing physical text batches are refused without resetting the current batch', function()
  local f = fixture()
  expect.equal(f.source:text('unbound', 1).kind, 'refused', 'no begun batch')
  f.source:beginBatch(12)
  expect.equal(f.source:text('old', 11).kind, 'refused', 'old batch')
  expect.equal(f.source:text('missing').kind, 'refused', 'missing batch')
  expect.equal(f.source:text('current', 12).kind, 'consumed', 'still the current batch')
  expect.equal(#f.texts, 1, 'one accepted text')
  f.inverse()
end)

test('consumed-key text poisoning does not suppress later keys in the same batch', function()
  local calls = 0
  local f = fixture(function()
    calls += 1
    return true
  end)
  f.source:beginBatch(20)
  expect.equal(f.source:key({ code = 30, batch = 20 }).kind, 'consumed', 'first key')
  expect.equal(f.source:key({ code = 31, batch = 20 }).kind, 'consumed', 'second key')
  expect.equal(calls, 2, 'both keys reach the receiver')
  expect.equal(f.source:text('duplicates', 20).kind, 'refused', 'text remains poisoned')
  f.inverse()
end)

test('beginning the same batch again cannot erase consumed-key text poisoning', function()
  local f = fixture(function()
    return true
  end)
  f.source:beginBatch(30)
  f.source:key { code = 30, batch = 30 }
  f.source:beginBatch(30)
  expect.equal(f.source:text('duplicate', 30).kind, 'refused', 'the same batch stays poisoned')
  f.inverse()
end)

test('a consumed key poisons only its original batch when its callback begins the next batch', function()
  local f
  f = fixture(function()
    f.source:beginBatch(41)
    return true
  end)
  f.source:beginBatch(40)
  expect.equal(f.source:key({ code = 30, batch = 40 }).kind, 'consumed', 'the original key')
  expect.equal(f.source:text('next', 41).kind, 'consumed', 'the callback started a fresh batch')
  f.inverse()
end)

return test
