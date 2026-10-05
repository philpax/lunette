local testing = require '@testing'
local expect = testing.expect
local frame = require '@lunette-contracts/frame'

local test = testing.suite()

local function start()
  local session = testing.boot { 'frame' }
  local observed = session:observe(frame.capability)
  return session, observed.service, observed.context
end

test('a consumed binding key replaces the batch metadata with the same ID and notifies observers', function()
  local session, service, owner = start()
  local batches, late, textBatches, trace = {}, {}, {}, {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
      trace[#trace + 1] = if batch.textBlocked then 'blocked' else 'open'
    end,
  })
  service:onKey(owner, {
    phase = 'binding',
    run = function()
      trace[#trace + 1] = 'binding'
      return true
    end,
  })
  service:onKey(owner, {
    phase = 'delivery',
    run = function()
      trace[#trace + 1] = 'key-delivery'
    end,
  })
  service:onText(owner, {
    phase = 'delivery',
    run = function(event)
      textBatches[#textBatches + 1] = event.batch
      trace[#trace + 1] = 'text-delivery'
    end,
  })
  lovr.keypressed('q', 16, false)
  expect.equal(table.concat(trace, ' '), 'open binding blocked', 'the consumed key reaches no delivery handler')
  expect.equal(#batches, 2, 'opening and changed metadata each notify observers')
  expect.equal(batches[1].textBlocked, false, 'opening permits physical text')
  expect.equal(batches[2].textBlocked, true, 'the consumed key blocks physical text')
  expect.equal(batches[2].id, batches[1].id, 'the metadata change does not advance the batch')
  expect.truthy(batches[2] ~= batches[1], 'the changed metadata has its own immutable table')
  expect.equal(batches[1].textBlocked, false, 'the old immutable batch remains unchanged')
  expect.raises(function()
    batches[2].textBlocked = false
  end, 'readonly', 'blocked metadata is frozen')
  service:onBatch(owner, {
    run = function(batch)
      late[#late + 1] = batch
    end,
  })
  expect.equal(late[1], batches[2], 'late registration receives the exact changed batch')
  lovr.keypressed('q', 16, true)
  lovr.textinput('unrelated', 117)
  expect.equal(#batches, 2, 'another consumption and text callback do not repeat unchanged metadata')
  expect.equal(textBatches[1], batches[2].id, 'text keeps the original event batch')
  expect.equal(#late, 1, 'late observers receive no duplicate notification for unchanged metadata')
  session:update()
  expect.equal(#batches, 3, 'the next update opens one batch')
  expect.equal(batches[3].id, batches[2].id + 1, 'the update advances the batch')
  expect.equal(batches[3].textBlocked, false, 'the next update restores physical text')
  expect.equal(late[2], batches[3], 'all observers share the new immutable batch')
  session:close()
end)

test('delivery consumption and consumed text do not block the batch or correlate later text', function()
  local session, service, owner = start()
  local batches, delivered = {}, {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
    end,
  })
  service:onKey(owner, {
    phase = 'delivery',
    run = function()
      return true
    end,
  })
  service:onText(owner, {
    phase = 'binding',
    run = function(event)
      return event.text == 'q'
    end,
  })
  service:onText(owner, {
    phase = 'delivery',
    run = function(event)
      delivered[#delivered + 1] = event.text
    end,
  })
  lovr.keypressed('q', 16, false)
  lovr.textinput('q', 113)
  lovr.textinput('é🙂', 233)
  expect.equal(#batches, 1, 'only the initial batch is notified')
  expect.equal(batches[1].textBlocked, false, 'only binding-phase key consumption blocks physical text')
  expect.equal(table.concat(delivered, '|'), 'é🙂', 'a consumed text callback affects only itself')
  session:close()
end)

test('raising key bindings fall through without blocking batch metadata', function()
  local session, service, owner = start()
  local batches, trace = {}, {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
    end,
  })
  service:onKey(owner, {
    phase = 'binding',
    run = function()
      error 'raising binding'
    end,
  })
  service:onKey(owner, {
    phase = 'delivery',
    run = function()
      trace[#trace + 1] = 'key'
    end,
  })
  service:onText(owner, {
    phase = 'delivery',
    run = function()
      trace[#trace + 1] = 'text'
    end,
  })
  lovr.keypressed('q', 16, false)
  lovr.textinput('q', 113)
  expect.equal(table.concat(trace, ' '), 'key text', 'a raising binding consumes nothing')
  expect.equal(#batches, 1, 'the failed callback changes no metadata')
  expect.equal(batches[1].textBlocked, false, 'the batch remains eligible')
  expect.equal(#session.native.events.reported, 1, 'the binding error is reported')
  expect.truthy(session.native.events.reported[1].message:find('raising binding', 1, true))
  session:close()
end)

test('a reentered update does not block its new batch when the previous key is consumed', function()
  local session, service, owner = start()
  local batches = {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
    end,
  })
  service:onKey(owner, {
    phase = 'binding',
    run = function()
      session:update()
      return true
    end,
  })
  lovr.keypressed('q', 16, false)
  expect.equal(#batches, 2, 'only the initial and reentered update boundaries notify')
  expect.equal(batches[2].id, batches[1].id + 1, 'the reentered update opens another batch')
  expect.equal(batches[2].textBlocked, false, 'consumption from the old batch cannot block the new one')
  session:close()
end)

return test
