local testing = require '@testing'
local expect = testing.expect
local frame = require '@lunette-contracts/frame'

local test = testing.suite()

local function start()
  local session = testing.boot { 'frame' }
  local observed = session:observe(frame.capability)
  return session, observed.service, observed.context
end

local function record(trace, label)
  return function()
    trace[#trace + 1] = label
  end
end

test('update and the first key or text open a batch that events carry, and observers run first', function()
  local session, service, owner = start()
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
  lovr.keypressed(
    'a',
    4,
    false,
    { shift = true, control = false, alt = false, super = false, capsLock = false, numLock = true }
  )
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
  end
  expect.truthy(events[1].modifiers.shift and events[1].modifiers.numLock, 'the key carries its modifiers')
  expect.equal(events[3].modifiers, nil, 'nil means the backend has no snapshot')
  table.clear(trace)
  session:update()
  expect.equal(table.concat(trace, ' '), 'batch second-batch update', 'update opens its batch first')
  expect.equal(batches[2].id, batches[1].id + 1, 'the next boundary advances the ID')
  local late
  service:onBatch(owner, {
    run = function(batch)
      late = batch
    end,
  })
  expect.equal(late, batches[2], 'a late observer receives the current batch')
  lovr.textinput('b', 98)
  expect.equal(events[#events].batch, batches[2].id, 'input following update uses its batch')
  session:close()
end)

test('a consumed binding key blocks text until the next update, and delivery consumption does not', function()
  local session, service, owner = start()
  local batches, trace = {}, {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
      trace[#trace + 1] = if batch.textBlocked then 'blocked' else 'open'
    end,
  })
  service:onKey(owner, {
    phase = 'binding',
    run = function(event)
      trace[#trace + 1] = 'binding'
      return event.key == 'q'
    end,
  })
  service:onKey(owner, {
    phase = 'delivery',
    run = function()
      trace[#trace + 1] = 'key-delivery'
      return true
    end,
  })
  lovr.keypressed('q', 16, false)
  expect.equal(table.concat(trace, ' '), 'open binding blocked', 'the consumed key reaches no delivery handler')
  expect.equal(batches[2].id, batches[1].id, 'the metadata change does not advance the batch')
  expect.equal(batches[1].textBlocked, false, 'the old batch remains unchanged')
  expect.equal(batches[2].textBlocked, true, 'the consumed key blocks physical text')
  lovr.keypressed('q', 16, true)
  expect.equal(#batches, 2, 'another consumption does not repeat unchanged metadata')
  session:update()
  expect.equal(batches[3].id, batches[2].id + 1, 'the update advances the batch')
  expect.equal(batches[3].textBlocked, false, 'the next update restores physical text')
  lovr.keypressed('w', 26, false)
  expect.equal(#batches, 3, 'delivery consumption does not block physical text')
  session:close()
end)

test('blockText accepts only the current batch, and an ended activation cached method refuses', function()
  local session, service, owner = start()
  local blockText = service.blockText
  local batches = {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
    end,
  })
  expect.falsy(service:blockText(1), 'invalidation cannot open an absent batch')
  expect.equal(#batches, 0, 'an absent-batch request notifies nobody')
  session:update()
  local opened = batches[1]
  expect.truthy(service:blockText(opened.id), 'the current batch accepts invalidation')
  expect.equal(batches[2].id, opened.id, 'invalidation keeps the same batch id')
  expect.equal(batches[2].textBlocked, true, 'the replacement is blocked')
  expect.truthy(service:blockText(opened.id), 'repeated current-batch invalidation succeeds')
  expect.falsy(service:blockText(opened.id + 1), 'a future id cannot invalidate the current batch')
  expect.equal(#batches, 2, 'unchanged and rejected requests emit no notifications')
  session:update()
  expect.equal(batches[3].textBlocked, false, 'the next update restores text')
  expect.falsy(service:blockText(opened.id), 'the previous id cannot invalidate the next batch')
  local current = batches[3]
  session.instances.frame:disable()
  expect.falsy(blockText(service, current.id), 'an ended provider rejects a cached operation')
  session:close()
end)

test('an observer error is reported and dispatch continues', function()
  local session, service, owner = start()
  local trace = {}
  service:onBatch(owner, {
    run = function()
      error 'batch boundary failure'
    end,
  })
  service:onBatch(owner, { run = record(trace, 'batch') })
  service:onKey(owner, { run = record(trace, 'key') })
  lovr.keypressed('a', 4, false)
  expect.equal(table.concat(trace, ' '), 'batch key', 'an observer error does not stop dispatch')
  local reports = session.native.events.reported
  expect.equal(#reports, 1, 'the boundary error is reported')
  expect.truthy(reports[1].message:find('frame.onBatch: ', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('batch boundary failure', 1, true), reports[1].message)
  testing.takeReports()
  session:close()
end)

return test
