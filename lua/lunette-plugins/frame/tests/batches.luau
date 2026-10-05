local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'

local test = testing.suite()

local function start()
  local session = testing.boot { 'frame' }
  local observed = session:observe(frame.capability)
  return session, observed
end

local function record(trace, label)
  return function()
    trace[#trace + 1] = label
  end
end

test('batches open lazily before input and at every update before any handler', function()
  local session, observed = start()
  local service, owner = observed.service, observed.context
  local trace, batches, events = {}, {}, {}
  service:onKey(owner, { phase = 'delivery', run = record(trace, 'key-delivery') })
  service:onText(owner, { phase = 'delivery', run = record(trace, 'text-delivery') })
  service:onKey(owner, {
    order = -100000,
    run = function(event)
      trace[#trace + 1] = 'key-binding'
      events[#events + 1] = event
    end,
  })
  service:onText(owner, {
    run = function(event)
      trace[#trace + 1] = 'text-binding'
      events[#events + 1] = event
    end,
  })
  service:onUpdate(owner, { phase = 'input', order = -10000, run = record(trace, 'update') })
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
      trace[#trace + 1] = 'batch'
    end,
  })
  service:onBatch(owner, { run = record(trace, 'second-batch') })
  expect.equal(#trace, 0, 'registration before the first boundary is lazy')
  session:draw()
  expect.equal(#trace, 0, 'draw is not a batch boundary')
  lovr.keypressed('a', 4, false)
  lovr.textinput('a', 97)
  lovr.keypressed('b', 5, true)
  expect.equal(
    table.concat(trace, ' '),
    'batch second-batch key-binding key-delivery text-binding text-delivery key-binding key-delivery',
    'all observers run before binding and delivery'
  )
  expect.equal(#batches, 1, 'multiple events share the lazy batch')
  for _, event in ipairs(events) do
    expect.equal(event.batch, batches[1].id, 'the physical event batch')
    expect.raises(function()
      event.batch = 900
    end, 'readonly', 'the event batch is frozen')
  end
  expect.raises(function()
    batches[1].id = 900
  end, 'readonly', 'the batch is frozen')
  table.clear(trace)
  session:update()
  expect.equal(table.concat(trace, ' '), 'batch second-batch update', 'update opens its batch first')
  expect.equal(batches[2].id, batches[1].id + 1, 'the next boundary advances the ID')
  lovr.textinput('b', 98)
  expect.equal(events[#events].batch, batches[2].id, 'input following update uses its batch')
  session:update()
  session:update()
  expect.equal(#batches, 4, 'updates without events still open batches')
  session:close()
end)

test('key snapshots are validated and frozen before batch observers and key handlers', function()
  local session, observed = start()
  local flags = { shift = true, control = false, alt = false, super = false, capsLock = false, numLock = true }
  local events = {}
  observed.service:onBatch(observed.context, {
    run = function()
      flags.shift = false
      flags.numLock = false
    end,
  })
  observed.service:onKey(observed.context, {
    run = function(event)
      events[#events + 1] = event
    end,
  })
  lovr.keypressed('kp1', 79, false, flags)
  expect.truthy(events[1].modifiers ~= flags, 'the callback table is not retained')
  expect.truthy(events[1].modifiers.shift and events[1].modifiers.numLock, 'flags precede observer side effects')
  expect.raises(function()
    events[1].modifiers.shift = false
  end, 'readonly', 'the nested snapshot is immutable')
  lovr.keypressed('kp1', 79, false)
  expect.equal(events[2].modifiers, nil, 'nil means the backend has no snapshot')
  flags.extra = true
  expect.raises(function()
    lovr.keypressed('kp1', 79, false, flags)
  end, 'contains only', 'extra flags fail at the frame boundary')
  expect.raises(function()
    lovr.keypressed('kp1', 79, false, false)
  end, 'plain table', 'false is not unavailable metadata')
  expect.equal(#events, 2, 'invalid snapshots cannot reach handlers')
  session:close()
end)

test('a text-first callback opens the lazy initial batch even when a binding consumes it', function()
  local session, observed = start()
  local trace, id = {}, nil
  observed.service:onText(observed.context, {
    run = function(event)
      expect.equal(event.batch, id, 'the observer initialized the batch before binding')
      trace[#trace + 1] = 'binding'
      return true
    end,
  })
  observed.service:onText(observed.context, { phase = 'delivery', run = record(trace, 'delivery') })
  observed.service:onBatch(observed.context, {
    run = function(batch)
      id = batch.id
      trace[#trace + 1] = 'batch'
    end,
  })
  lovr.textinput('x', 120)
  expect.equal(table.concat(trace, ' '), 'batch binding', 'batch notification cannot be consumed by a binding')
  session:close()
end)

test('late observers immediately receive the current batch without dispatching consumers', function()
  local session, observed = start()
  local service, owner = observed.service, observed.context
  local current, calls = nil, 0
  service:onBatch(owner, {
    run = function(batch)
      current = batch
    end,
  })
  service:onKey(owner, {
    run = function()
      calls += 1
    end,
  })
  service:onText(owner, {
    run = function()
      calls += 1
    end,
  })
  session:update()
  local received = {}
  local effect = service:onBatch(owner, {
    run = function(batch)
      received[#received + 1] = batch
    end,
  })
  expect.equal(#received, 1, 'registration initializes the current batch')
  expect.equal(received[1], current, 'registration receives the same immutable batch')
  expect.equal(calls, 0, 'registration dispatches no key or text consumers')
  session:update()
  expect.equal(#received, 2, 'the next boundary notifies once')
  effect:dispose()
  effect:dispose()
  session:update()
  expect.equal(#received, 2, 'disposed observers receive no later batches')
  session:close()
end)

test('observer errors are reported without suppressing later observers or input', function()
  local session, observed = start()
  local trace = {}
  observed.service:onBatch(observed.context, {
    run = function()
      error 'batch boundary failure'
    end,
  })
  observed.service:onBatch(observed.context, { run = record(trace, 'batch') })
  observed.service:onKey(observed.context, { run = record(trace, 'key') })
  lovr.keypressed('a', 4, false)
  expect.equal(table.concat(trace, ' '), 'batch key', 'an observer error does not stop dispatch')
  local reports = session.native.events.reported
  expect.equal(#reports, 1, 'the boundary error is reported')
  expect.truthy(reports[1].message:find('frame.onBatch: ', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('batch boundary failure', 1, true), reports[1].message)
  table.clear(reports)
  local late = observed.service:onBatch(observed.context, {
    run = function()
      error 'batch registration failure'
    end,
  })
  expect.equal(#reports, 1, 'the immediate notification error is reported')
  expect.truthy(reports[1].message:find('frame.onBatch: ', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('batch registration failure', 1, true), reports[1].message)
  late:dispose()
  session:close()
end)

test('observer disposal during notification skips it and new observers receive the current batch once', function()
  local session, observed = start()
  local trace, later, added = {}, nil, nil
  observed.service:onBatch(observed.context, {
    run = function()
      trace[#trace + 1] = 'first'
      if later then
        later:dispose()
      end
      if not added then
        added = observed.service:onBatch(observed.context, { run = record(trace, 'added') })
      end
    end,
  })
  later = observed.service:onBatch(observed.context, { run = record(trace, 'disposed') })
  session:update()
  expect.equal(table.concat(trace, ' '), 'first added', 'new and disposed registrations during notification')
  table.clear(trace)
  session:update()
  expect.equal(table.concat(trace, ' '), 'first added', 'the new observer participates once next time')
  session:close()
end)

test('batch observers validate plain handlers and genuine owners before immediate notification', function()
  local session, observed = start()
  local service, owner = observed.service, observed.context
  session:update()
  expect.raises(function()
    service:onBatch(owner, function() end)
  end, 'frame onBatch: a handler is a table of fields, not a function', 'a function instead of fields')
  expect.raises(function()
    service:onBatch(owner, { phase = 'input', run = function() end })
  end, 'frame onBatch: unknown field phase; the field is run', 'observers have no phase')
  expect.raises(function()
    service:onBatch(owner, { run = 1 })
  end, 'frame onBatch: run is a function, not a number', 'a wrong callback')
  expect.raises(function()
    service:onBatch(owner, setmetatable({}, { __index = { run = function() end } }))
  end, 'frame onBatch: a handler is a plain table', 'a metatable cannot supply a callback')
  local calls = 0
  expect.raises(function()
    service:onBatch({}, {
      run = function()
        calls += 1
      end,
    })
  end, 'owner', 'a forged owner')
  local unrelated
  local outsider = session:use(plugin.define {
    name = 'batch-outsider',
    init = function(context)
      unrelated = context
    end,
  })
  expect.raises(function()
    service:onBatch(unrelated, {
      run = function()
        calls += 1
      end,
    })
  end, 'does not depend on this provider', 'an owner without a dependency')
  outsider:disable()
  expect.equal(calls, 0, 'invalid owners receive no immediate notification')
  session:close()
end)

test('provider disposal during batch notification stops the remaining observers and input dispatch', function()
  local session, observed = start()
  local trace = {}
  observed.service:onBatch(observed.context, {
    run = function()
      trace[#trace + 1] = 'batch'
      session.instances.frame:disable()
    end,
  })
  observed.service:onBatch(observed.context, { run = record(trace, 'later-batch') })
  observed.service:onKey(observed.context, { run = record(trace, 'key') })
  observed.service:onText(observed.context, { run = record(trace, 'text') })
  lovr.keypressed('a', 4, false)
  lovr.textinput('a', 97)
  expect.equal(table.concat(trace, ' '), 'batch', 'disposed activation state cannot deliver input')
  session:close()
end)

test('outages and owner recovery invalidate old batch registrations and service generations', function()
  local session = testing.boot { 'frame' }
  local captured, batches = {}, {}
  local consumer = session:use(plugin.define {
    name = 'batch-generation',
    requires = { frame = frame.capability },
    init = function(context)
      local service = context:require(frame.capability)
      captured[#captured + 1] = { service = service, owner = context }
      service:onBatch(context, {
        run = function(batch)
          batches[#batches + 1] = batch
        end,
      })
    end,
  })
  session:update()
  consumer:disable()
  session:update()
  expect.equal(#batches, 1, 'a disabled owner receives no batches')
  consumer:enable()
  expect.equal(#batches, 2, 'owner recovery receives the current batch immediately')
  expect.equal(batches[2].id, batches[1].id + 1, 'owner recovery retains the active provider batch')
  local provider = session.instances.frame
  provider:disable()
  session:update()
  lovr.keypressed('a', 4, false)
  lovr.textinput('a', 97)
  expect.equal(#batches, 2, 'outage callbacks do nothing')
  provider:enable()
  expect.equal(#batches, 2, 'provider recovery starts without a current batch')
  local latest = captured[#captured]
  local calls = 0
  expect.raises(function()
    captured[1].service:onBatch(latest.owner, {
      run = function()
        calls += 1
      end,
    })
  end, 'provider activation has ended', 'an old provider generation')
  expect.raises(function()
    latest.service:onBatch(captured[1].owner, {
      run = function()
        calls += 1
      end,
    })
  end, 'the caller is not loading or active', 'an old owner generation')
  expect.equal(calls, 0, 'stale generations receive no immediate notification')
  lovr.textinput('b', 98)
  expect.equal(#batches, 3, 'recovered input opens one lazy batch')
  expect.truthy(batches[3] ~= batches[2], 'the old immutable batch is not reused')
  session:close()
  session:update()
  lovr.keypressed('a', 4, false)
  expect.equal(#batches, 3, 'closed providers receive no batches')
end)

return test
