local testing = require '@testing'
local frame = require '@lunette-contracts/frame'
local expect = testing.expect
local test = testing.suite()

local function start()
  local session = testing.boot { 'frame' }
  local observed = session:observe(frame.capability)
  return session, observed.service, observed.context
end

test('blocking text replaces immutable metadata once and publishes state before observers run', function()
  local session, service, owner = start()
  local batches, late = {}, {}
  local registered = false
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
      if batch.textBlocked then
        expect.truthy(service:blockText(batch.id), 'a reentrant request is already satisfied')
        if not registered then
          registered = true
          service:onBatch(owner, {
            run = function(current)
              late[#late + 1] = current
            end,
          })
        end
      end
    end,
  })
  expect.falsy(service:blockText(1), 'invalidation cannot open an absent batch')
  expect.equal(#batches, 0, 'an absent-batch request notifies nobody')
  session:update()
  local opened = batches[1]
  expect.truthy(service:blockText(opened.id), 'the current batch accepts invalidation')
  local blocked = batches[2]
  expect.equal(#batches, 2, 'opening and one immutable replacement notify observers')
  expect.truthy(blocked ~= opened, 'invalidation replaces rather than mutates the snapshot')
  expect.equal(opened.textBlocked, false, 'the retained opening snapshot stays unchanged')
  expect.equal(blocked.id, opened.id, 'invalidation keeps the same batch id')
  expect.equal(blocked.textBlocked, true, 'the replacement is blocked')
  expect.equal(late[1], blocked, 'a new observer sees the replacement during notification')
  expect.raises(function()
    blocked.textBlocked = false
  end, 'readonly', 'the replacement is immutable')
  expect.truthy(service:blockText(opened.id), 'repeated current-batch invalidation succeeds')
  expect.falsy(service:blockText(opened.id + 1), 'a future id cannot invalidate the current batch')
  expect.equal(#batches, 2, 'unchanged and rejected requests emit no notifications')
  session:update()
  expect.equal(batches[3].textBlocked, false, 'the next update restores text')
  expect.falsy(service:blockText(opened.id), 'the previous id cannot invalidate the next batch')
  expect.equal(#batches, 3, 'a stale request changes no metadata')
  session:close()
end)

test('an ended frame activation cannot block a replacement activation with the same numeric id', function()
  local session, service, owner = start()
  local blockText = service.blockText
  local oldBatch
  service:onBatch(owner, {
    run = function(batch)
      oldBatch = batch
    end,
  })
  session:update()
  session.instances.frame:disable()
  expect.raises(function()
    service:blockText(oldBatch.id)
  end, 'provider activation has ended', 'an ended service rejects fresh method lookup')
  expect.falsy(blockText(service, oldBatch.id), 'an ended provider rejects a cached operation')
  session.instances.frame:enable()
  local replacement = session:observe(frame.capability)
  local current
  replacement.service:onBatch(replacement.context, {
    run = function(batch)
      current = batch
    end,
  })
  session:update()
  expect.equal(current.id, oldBatch.id, 'separate activations may reuse a numeric id')
  expect.falsy(blockText(service, current.id), 'the old generation cannot invalidate the replacement')
  expect.equal(current.textBlocked, false, 'the replacement remains eligible')
  expect.truthy(replacement.service:blockText(current.id), 'the current generation accepts invalidation')
  expect.equal(current.textBlocked, true, 'the current generation publishes blocked metadata')
  local replacementBlockText = replacement.service.blockText
  session:close()
  expect.falsy(replacementBlockText(replacement.service, current.id), 'normal shutdown ends invalidation authority')
end)

test('an explicit request from a reentered old key cannot block the new update batch', function()
  local session, service, owner = start()
  local batches = {}
  service:onBatch(owner, {
    run = function(batch)
      batches[#batches + 1] = batch
    end,
  })
  service:onKey(owner, {
    phase = 'delivery',
    run = function(event)
      session:update()
      expect.falsy(service:blockText(event.batch), 'the reentered update makes the event batch stale')
      return true
    end,
  })
  lovr.keypressed('q', 16, false)
  expect.equal(#batches, 2, 'only the lazy batch and reentered update notify observers')
  expect.equal(batches[2].textBlocked, false, 'the new batch remains eligible')
  session:close()
end)

test('blocking during batch opening never redelivers superseded open metadata to later observers', function()
  local session, service, owner = start()
  local later = {}
  service:onBatch(owner, {
    run = function(batch)
      if not batch.textBlocked then
        service:blockText(batch.id)
      end
    end,
  })
  service:onBatch(owner, {
    run = function(batch)
      later[#later + 1] = batch
    end,
  })
  session:update()
  expect.equal(#later, 1, 'the later observer receives only the current replacement snapshot')
  expect.equal(later[1].textBlocked, true, 'superseded open metadata cannot renew physical text')
  session:close()
end)

return test
