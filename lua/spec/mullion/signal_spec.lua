-- Covers lua/mullion/signal.lua.

local expect = require 'spec.expect'
local suite = require 'spec.suite'

local signal = require 'mullion.signal'

local spec = suite.new 'mullion.signal'

-- A fresh object to hang signals on. Signals are keyed by identity, so every
-- case gets its own and nothing a case connects reaches another.
local function object()
  return {}
end

-- Records what a handler was called with, and returns the handler and the log.
local function recorder()
  local calls = {}
  return function(...)
    calls[#calls + 1] = { ... }
  end, calls
end

spec('calls a connected handler with the object and the arguments', function()
  local target = object()
  local handler, calls = recorder()

  signal.connect(target, 'moved', handler)
  signal.emit(target, 'moved', 1, 'two')

  expect.equal(#calls, 1, 'call count')
  expect.equal(calls[1][1], target, 'first argument')
  expect.equal(calls[1][2], 1, 'second argument')
  expect.equal(calls[1][3], 'two', 'third argument')
end)

spec('calls handlers in the order they were connected', function()
  local target = object()
  local order = {}

  signal.connect(target, 'moved', function()
    order[#order + 1] = 'first'
  end)
  signal.connect(target, 'moved', function()
    order[#order + 1] = 'second'
  end)
  signal.emit(target, 'moved')

  expect.equal(table.concat(order, ','), 'first,second', 'order')
end)

spec('stops calling a handler that was disconnected', function()
  local target = object()
  local handler, calls = recorder()

  signal.connect(target, 'moved', handler)
  expect.truthy(signal.disconnect(target, 'moved', handler), 'disconnect')
  signal.emit(target, 'moved')

  expect.equal(#calls, 0, 'call count')
end)

spec('reports that a handler which was never connected was not disconnected', function()
  local target = object()

  expect.falsy(signal.disconnect(target, 'moved', function() end), 'disconnect')
end)

spec('disconnects one of two identical connections, leaving the other', function()
  local target = object()
  local handler, calls = recorder()

  signal.connect(target, 'moved', handler)
  signal.connect(target, 'moved', handler)
  signal.disconnect(target, 'moved', handler)
  signal.emit(target, 'moved')

  expect.equal(#calls, 1, 'call count')
end)

spec('emitting a signal with no handlers does nothing', function()
  local target = object()

  signal.emit(target, 'never-connected', 1, 2, 3)
  expect.equal(signal.connectionCount(target, 'never-connected'), 0, 'connection count')
end)

spec('a handler connected during an emission is not called by that emission', function()
  local target = object()
  local later, laterCalls = recorder()

  signal.connect(target, 'moved', function()
    signal.connect(target, 'moved', later)
  end)
  signal.emit(target, 'moved')

  expect.equal(#laterCalls, 0, 'calls during the first emission')

  signal.emit(target, 'moved')
  expect.equal(#laterCalls, 1, 'calls during the second emission')
end)

spec('a handler disconnecting another during an emission still runs it', function()
  local target = object()
  local second, secondCalls = recorder()

  signal.connect(target, 'moved', function()
    signal.disconnect(target, 'moved', second)
  end)
  signal.connect(target, 'moved', second)
  signal.emit(target, 'moved')

  -- The snapshot was taken before the first handler ran, so the second is
  -- called this time and not the next. Asserting both halves, because a
  -- snapshot that was never taken would pass the second on its own.
  expect.equal(#secondCalls, 1, 'calls during the emission that disconnected it')

  signal.emit(target, 'moved')
  expect.equal(#secondCalls, 1, 'calls after it was disconnected')
end)

spec('an error a handler raises propagates rather than being swallowed', function()
  local target = object()
  local after, afterCalls = recorder()

  signal.connect(target, 'moved', function()
    error 'the handler said no'
  end)
  signal.connect(target, 'moved', after)

  expect.raises(function()
    signal.emit(target, 'moved')
  end, 'the handler said no', 'emit')
  expect.equal(#afterCalls, 0, 'handlers after the one that raised')
end)

spec('rejects a handler that is not a function', function()
  local target = object()

  expect.raises(function()
    signal.connect(target, 'moved', 'not a function')
  end, 'a handler is a function', 'connect')
end)

spec('rejects a signal name that is not a string', function()
  local target = object()

  expect.raises(function()
    signal.connect(target, 42, function() end)
  end, 'named by a string', 'connect')
end)

spec('rejects a nil object', function()
  expect.raises(function()
    signal.connect(nil, 'moved', function() end)
  end, 'nil is not one', 'connect')
end)

spec('a weakly connected handler is called while something still holds it', function()
  local target = object()
  local handler, calls = recorder()

  signal.weakConnect(target, 'moved', handler)
  collectgarbage()
  signal.emit(target, 'moved')

  expect.equal(#calls, 1, 'call count')
end)

spec('a weakly connected handler goes when nothing else holds it', function()
  local target = object()
  local calls = 0
  local handler = function()
    calls = calls + 1
  end

  signal.weakConnect(target, 'moved', handler)
  handler = nil
  collectgarbage()
  collectgarbage()

  signal.emit(target, 'moved')
  expect.equal(calls, 0, 'call count')
  expect.equal(signal.connectionCount(target, 'moved'), 0, 'connection count')
end)

spec('a strongly connected handler survives a collection', function()
  local target = object()
  local calls = 0
  local handler = function()
    calls = calls + 1
  end

  signal.connect(target, 'moved', handler)
  handler = nil
  collectgarbage()
  collectgarbage()

  signal.emit(target, 'moved')
  expect.equal(calls, 1, 'call count')
end)

spec('a connection does not keep its object alive', function()
  local target = object()
  local watch = setmetatable({ target }, { __mode = 'v' })

  -- The handler must not close over `target`: Lua 5.1 has no ephemeron
  -- tables, so a strongly held handler that captured its own object would
  -- keep the registry's key reachable. That is the limitation weakConnect
  -- exists for, and it is documented at the module head.
  signal.connect(target, 'moved', function() end)
  target = nil
  collectgarbage()
  collectgarbage()

  expect.equal(watch[1], nil, 'the object after a collection')
end)

spec('disconnectAll drops every connection on an object', function()
  local target = object()
  local moved, movedCalls = recorder()
  local resized, resizedCalls = recorder()

  signal.connect(target, 'moved', moved)
  signal.connect(target, 'resized', resized)
  signal.disconnectAll(target)
  signal.emit(target, 'moved')
  signal.emit(target, 'resized')

  expect.equal(#movedCalls, 0, 'moved calls')
  expect.equal(#resizedCalls, 0, 'resized calls')
end)

spec('disconnectAll on one name leaves the others', function()
  local target = object()
  local moved, movedCalls = recorder()
  local resized, resizedCalls = recorder()

  signal.connect(target, 'moved', moved)
  signal.connect(target, 'resized', resized)
  signal.disconnectAll(target, 'moved')
  signal.emit(target, 'moved')
  signal.emit(target, 'resized')

  expect.equal(#movedCalls, 0, 'moved calls')
  expect.equal(#resizedCalls, 1, 'resized calls')
end)

spec('setProperty writes the value and announces the change', function()
  local target = object()
  local handler, calls = recorder()

  signal.connect(target, signal.propertyName 'title', handler)
  local changed = signal.setProperty(target, 'title', 'a terminal')

  expect.truthy(changed, 'setProperty')
  expect.equal(target.title, 'a terminal', 'the property')
  expect.equal(#calls, 1, 'call count')
  expect.equal(calls[1][2], 'a terminal', 'the new value')
  expect.equal(calls[1][3], nil, 'the old value')
end)

spec('setProperty carries the previous value', function()
  local target = object()
  local handler, calls = recorder()

  signal.setProperty(target, 'title', 'before')
  signal.connect(target, signal.propertyName 'title', handler)
  signal.setProperty(target, 'title', 'after')

  expect.equal(calls[1][2], 'after', 'the new value')
  expect.equal(calls[1][3], 'before', 'the old value')
end)

spec('setProperty announces nothing when the value did not change', function()
  local target = object()
  local handler, calls = recorder()

  signal.setProperty(target, 'title', 'a terminal')
  signal.connect(target, signal.propertyName 'title', handler)
  local changed = signal.setProperty(target, 'title', 'a terminal')

  expect.falsy(changed, 'setProperty')
  expect.equal(#calls, 0, 'call count')
end)

spec('propertyName is the awesome spelling', function()
  expect.equal(signal.propertyName 'title', 'property::title', 'name')
end)

spec('propertyName rejects a key that is not a string', function()
  expect.raises(function()
    signal.propertyName(7)
  end, 'named by a string', 'propertyName')
end)

spec('requiring twice returns the same module and does not duplicate connections', function()
  local target = object()
  local handler, calls = recorder()

  signal.connect(target, 'moved', handler)
  local again = require 'mullion.signal'

  expect.equal(again, signal, 'the module')
  again.emit(target, 'moved')
  expect.equal(#calls, 1, 'call count')
  expect.equal(again.connectionCount(target, 'moved'), 1, 'connection count')
end)

spec('teardown discards every connection', function()
  local target = object()
  local handler, calls = recorder()

  signal.connect(target, 'moved', handler)
  signal.teardown()
  signal.emit(target, 'moved')

  expect.equal(#calls, 0, 'call count')
  expect.equal(signal.connectionCount(target, 'moved'), 0, 'connection count')
end)

return spec
