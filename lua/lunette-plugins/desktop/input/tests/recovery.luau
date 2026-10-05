local testing = require '@testing'
local physical = require './support/physical'
local expect = testing.expect
local test = physical.suite()

local function recover(f)
  f.session.instances['desktop/input']:disable()
  f.session.instances['desktop/input']:enable()
end

for _, destination in ipairs { 'window', 'host', 'local' } do
  test('a keypad command blocks text across same-batch input recovery for ' .. destination, function()
    local f = physical.boot(if destination == 'local' then nil else destination)
    local target = if destination == 'local' then f:localTarget 'field' else f.nativeTarget
    expect.truthy(target:focus(), 'the independently owned route acquires focus')
    local revision = f.focus:revision()
    f:held()
    f:pair('kp1', nil, false, physical.modifiers { control = true, numLock = true })
    local batch = f.batch
    local keyTrace = if destination == 'local'
      then 'field:key:79:physical:control+numLock:false'
      else 'mods:control+numLock|key:79:down|key:79:up|mods:'
    expect.equal(f:trace(), keyTrace, 'the command delivers exactly one keypad activation')
    expect.truthy(f.textBlocked, 'the command immediately persists blocked batch metadata')
    recover(f)
    expect.truthy(f.textBlocked, 'recovery observes the unchanged blocked metadata')
    lovr.textinput('1', 49)
    expect.equal(f.batch, batch, 'recovery does not open a new batch')
    expect.equal(f.focus:revision(), revision, 'recovery leaves the independent focus route unchanged')
    expect.equal(f:trace(), keyTrace, 'the same-batch callback cannot duplicate the command as text')
    f:nextBatch()
    lovr.textinput('1', 49)
    expect.equal(
      f:trace(),
      keyTrace
        .. '|'
        .. (
          if destination == 'local'
            then 'field:text:1'
            elseif destination == 'host' then 'native-text:1'
            else 'resolve:1|mods:|key:2:down|key:2:up|mods:'
        ),
      'the next update restores independent text'
    )
    f:close()
  end)
end

for _, destination in ipairs { 'local', 'window', 'host' } do
  for _, cause in ipairs { 'command', 'binding' } do
    local name = 'later navigation keys survive ' .. cause .. ' text blocking and input recovery for ' .. destination
    test(name, function()
      local f = physical.boot(if destination == 'local' then nil else destination)
      local target = if destination == 'local' then f:localTarget 'field' else f.nativeTarget
      expect.truthy(target:focus(), 'the independently owned route acquires focus')
      if cause == 'command' then
        f:pair('kp1', nil, false, physical.modifiers { control = true, numLock = true })
      else
        local binding = f.frame:onKey(f.frameOwner, {
          phase = 'binding',
          run = function(event)
            return event.key == 'q'
          end,
        })
        f:pair('q', nil)
        binding:dispose()
      end
      expect.truthy(f.textBlocked, 'the original event blocks text')
      local batch = f.batch
      f:clear()
      recover(f)
      f:pair('left', nil, false, physical.modifiers())
      f:pair('left', nil, true, physical.modifiers())
      local navigation = if destination == 'local'
        then 'field:key:105:physical::false|field:key:105:physical::true'
        else 'mods:|key:105:down|key:105:up|mods:|mods:|key:105:down|key:105:up|mods:'
      expect.equal(f:trace(), navigation, 'later navigation and repeat reach the unchanged target')
      lovr.textinput('1', 49)
      expect.equal(f.batch, batch, 'later keys and text retain the blocked batch id')
      expect.truthy(f.textBlocked, 'navigation does not renew text eligibility')
      expect.equal(f:trace(), navigation, 'same-batch text remains rejected')
      f:nextBatch()
      lovr.textinput('1', 49)
      expect.equal(
        f:trace(),
        navigation
          .. '|'
          .. (
            if destination == 'local'
              then 'field:text:1'
              elseif destination == 'host' then 'native-text:1'
              else 'resolve:1|mods:|key:2:down|key:2:up|mods:'
          ),
        'the next update restores committed text'
      )
      f:close()
    end)
  end
end

for _, result in ipairs { 'consumed', 'failed', 'refused' } do
  test('a ' .. result .. ' local key blocks text across same-batch input recovery', function()
    local f = physical.boot()
    local nextTarget = f:localTarget 'next'
    local target = f:localTarget('field', {
      key = function()
        if result == 'failed' then
          error 'fixture recovery key failure'
        elseif result == 'refused' then
          expect.truthy(nextTarget:focus(), 'a receiver callback changes the route')
          return false
        end
        return true
      end,
    })
    expect.truthy(target:focus(), 'the independently owned field acquires focus')
    f:pair('q', nil)
    if result == 'failed' then
      expect.equal(#f.native.events.reported, 1, 'the receiver failure is reported once')
      table.clear(f.native.events.reported)
    end
    expect.truthy(f.textBlocked, 'the key result immediately persists blocked batch metadata')
    recover(f)
    lovr.textinput('1', 49)
    expect.equal(f:trace(), 'field:key:16:physical::false', 'the replacement source retains key text rejection')
    f:nextBatch()
    lovr.textinput('1', 49)
    expect.equal(
      f:trace(),
      'field:key:16:physical::false|' .. (if result == 'refused' then 'next:text:1' else 'field:text:1'),
      'the next update restores text to the current receiver'
    )
    f:close()
  end)
end

for _, destination in ipairs { 'local', 'native' } do
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

for _, outcome in ipairs { 'declined', 'consumed', 'failed' } do
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

return test.result
