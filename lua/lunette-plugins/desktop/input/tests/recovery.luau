local testing = require '@testing'
local physical = require './support/physical'
local expect = testing.expect
local test = physical.suite()

for _, destination in ipairs { 'local' } do
  test('a route change during input downtime cannot renew same-batch text for ' .. destination, function()
    local f = physical.boot 'host'
    local previous = f:localTarget 'previous'
    local nextTarget = if destination == 'local' then f:localTarget 'next' else f.nativeTarget
    expect.truthy(previous:focus(), 'the original field acquires focus')
    f:pair('q', nil)
    local batch = f.batch
    f.session.instances['desktop/input']:disable()
    expect.truthy(nextTarget:focus(), 'the replacement route acquires focus during downtime')
    f.session.instances['desktop/input']:enable()
    lovr.textinput('1', 49)
    expect.equal(f.batch, batch, 'the provider recovery retains the batch id')
    expect.equal(f:trace(), 'previous:key:16:physical::false', 'recovery does not retarget pending text')
    f:nextBatch()
    lovr.textinput('1', 49)
    expect.equal(
      f:trace(),
      'previous:key:16:physical::false|' .. (if destination == 'local' then 'next:text:1' else 'native-text:1'),
      'the next update accepts text for the new route'
    )
    f:close()
  end)
end

for _, outcome in ipairs { 'declined' } do
  test('input unloaded during a ' .. outcome .. ' receiver key cannot renew same-batch text', function()
    local f = physical.boot()
    local target = f:localTarget('field', {
      key = function()
        f.session.instances['desktop/input']:disable()
        if outcome == 'failed' then
          error 'fixture unloaded key failure'
        end
        return outcome == 'consumed'
      end,
    })
    expect.truthy(target:focus(), 'the independently owned field acquires focus')
    f:pair('q', nil)
    if outcome == 'failed' then
      expect.equal(#f.native.events.reported, 1, 'the receiver failure is reported once')
      table.clear(f.native.events.reported)
    end
    f.session.instances['desktop/input']:enable()
    lovr.textinput('1', 49)
    expect.equal(f:trace(), 'field:key:16:physical::false', 'unwinding the disposed input cannot restore text')
    f:nextBatch()
    lovr.textinput('1', 49)
    expect.equal(f:trace(), 'field:key:16:physical::false|field:text:1', 'the next update restores text')
    f:close()
  end)
end

test('input recovery observes existing batches and never restores same-batch text', function()
  do
    local f = physical.boot()
    local target = f:localTarget 'field'
    expect.truthy(target:focus(), 'the field acquires focus')
    local binding = f.frame:onKey(f.frameOwner, {
      phase = 'binding',
      run = function()
        return true
      end,
    })
    f:pair('q', 'q')
    binding:dispose()
    f.session.instances['desktop/input']:disable()
    f.session.instances['desktop/input']:enable()
    lovr.textinput('later', 108)
    expect.equal(f:trace(), '', 'a replacement physical source cannot accept a blocked batch')
    f:nextBatch()
    lovr.textinput('é🙂', 233)
    expect.equal(f:trace(), 'field:text:é🙂', 'the next boundary restores eligibility')
    f:close()
  end
  do
    local f = physical.boot()
    local consume = true
    local target = f:localTarget('field', {
      key = function()
        return consume
      end,
    })
    expect.truthy(target:focus(), 'the field acquires focus')
    f:pair('q', 'q')
    f.session.instances['desktop/input']:disable()
    f:nextBatch()
    f.session.instances['desktop/input']:enable()
    consume = false
    lovr.textinput('é🙂', 233)
    expect.equal(f:trace(), 'field:key:16:physical::false|field:text:é🙂', 'recovery initializes the current batch')
    f:close()
  end
end)

return test.result
