local testing = require '@testing'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local physical = require './support/physical'
local expect = testing.expect
local test = physical.suite()

local function fallthrough(f)
  local log = {}
  for _, method in ipairs { 'onKey', 'onText' } do
    f.frame[method](f.frame, f.frameOwner, {
      phase = 'delivery',
      order = 100,
      run = function()
        log[#log + 1] = method
      end,
    })
  end
  return log
end

test('unhandled local physical keys commit whole text once without native fallback', function()
  local f = physical.boot()
  local target = f:localTarget 'field'
  expect.truthy(target:focus(), 'the field acquires focus')
  local later = fallthrough(f)
  f:pair('q', 'q')
  f:pair('e', 'é🙂', true)
  expect.equal(
    f:trace(),
    'field:key:16:physical::false|field:text:q|field:key:18:physical::true|field:text:é🙂',
    'all activations and whole strings reach only the local receiver'
  )
  expect.equal(#later, 0, 'local unhandled input is consumed relative to fallback')
  f:close()
end)

test('local receivers see Shift and AltGr while command chords suppress committed text', function()
  local f = physical.boot()
  expect.truthy(f:localTarget('field'):focus(), 'the field acquires focus')
  f:held 'lshift'
  f:pair('q', 'Q')
  f:held 'ralt'
  f:pair('e', '€')
  f:held 'lctrl'
  f:pair('q', 'q')
  f:held 'lgui'
  f:pair('q', 'q')
  f:held 'lalt'
  f:pair('q', 'q')
  expect.equal(
    f:trace(),
    'field:key:16:physical:shift:false|field:text:Q|field:key:18:physical:mod5:false|field:text:€'
      .. '|field:key:16:physical:control:false|field:key:16:physical:logo:false|field:key:16:physical:alt:false',
    'text modifiers and command modifiers remain distinct'
  )
  f:close()
end)

test('a consumed physical key poisons its paired and later text until the next update', function()
  local f = physical.boot()
  local consume = true
  local target = f:localTarget('field', {
    key = function()
      return consume
    end,
  })
  expect.truthy(target:focus(), 'the field acquires focus')
  local later = fallthrough(f)
  f:pair('q', 'q')
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'field:key:16:physical::false', 'consumed-key text is never inserted')
  expect.equal(#later, 0, 'consumption and poisoned text do not fall through')
  consume = false
  f:nextBatch()
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'field:key:16:physical::false|field:text:é🙂', 'fresh independent text is accepted')
  f:close()
end)

test('a receiver key error poisons text and reports both source and receiver ownership', function()
  local f = physical.boot()
  local raises = true
  local target = f:localTarget('field', {
    key = function()
      if raises then
        error 'local physical key failure'
      end
      return false
    end,
  })
  expect.truthy(target:focus(), 'the field acquires focus')
  local later = fallthrough(f)
  f:pair('q', 'q')
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'field:key:16:physical::false', 'failed-key text is not delivered')
  expect.equal(#later, 0, 'failure is not unhandled')
  local reports = f.native.events.reported
  expect.equal(#reports, 1, 'one receiver diagnostic')
  expect.truthy(reports[1].message:find('focus: receiver', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('source owner', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('local physical key failure', 1, true), reports[1].message)
  table.clear(reports)
  raises = false
  f:nextBatch()
  f:pair('q', 'q')
  expect.equal(
    f:trace(),
    'field:key:16:physical::false|field:key:16:physical::false|field:text:q',
    'the next batch recovers normal delivery'
  )
  f:close()
end)

test('local text errors report once without native or later-handler fallback', function()
  local f = physical.boot()
  expect.truthy(
    f:localTarget('field', {
      text = function()
        error 'local committed text failure'
      end,
    }):focus(),
    'the field acquires focus'
  )
  local later = fallthrough(f)
  f:pair('q', 'é🙂')
  expect.equal(f:trace(), 'field:key:16:physical::false|field:text:é🙂', 'one whole-string receiver call')
  expect.equal(#later, 0, 'failed text never falls through')
  local reports = f.native.events.reported
  expect.equal(#reports, 1, 'one text diagnostic')
  expect.truthy(reports[1].message:find('focus: receiver', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('local committed text failure', 1, true), reports[1].message)
  table.clear(reports)
  f:close()
end)

test('focus changes during a local key never retarget its text into another field or application', function()
  for _, destination in ipairs { 'local', 'native' } do
    local f = physical.boot 'host'
    local nextTarget = if destination == 'local' then f:localTarget 'next' else f.nativeTarget
    local previous = f:localTarget('previous', {
      key = function()
        expect.truthy(nextTarget:focus(), 'the replacement acquires focus')
        return false
      end,
    })
    expect.truthy(previous:focus(), 'the original field acquires focus')
    local later = fallthrough(f)
    f:pair('q', 'q')
    lovr.textinput('stale', 115)
    expect.equal(f:trace(), 'previous:key:16:physical::false', 'no stale text reaches the replacement')
    expect.equal(#later, 0, 'route refusal never falls through')
    f:nextBatch()
    lovr.textinput('é🙂', 233)
    expect.equal(
      f:trace(),
      'previous:key:16:physical::false|'
        .. (if destination == 'local' then 'next:text:é🙂' else 'native-text:é🙂'),
      'fresh independent text uses only the current target'
    )
    f:close()
  end
end)

test('a receiver that unloads itself cannot leak paired text into the next focused target', function()
  local f = physical.boot 'host'
  local target, instance
  instance = f.session:use(plugin.define {
    name = 'physical-self-unload',
    requires = { focus = focus.capability },
    init = function(context)
      target = f:localTarget('unloading', {
        key = function()
          instance:disable()
          expect.truthy(f.nativeTarget:focus(), 'the application becomes current')
          return false
        end,
      }, context)
    end,
  })
  expect.truthy(target:focus(), 'the self-unloading receiver acquires focus')
  f:pair('q', 'q')
  expect.truthy(target.dead, 'the unloaded receiver is dead')
  expect.equal(f:trace(), 'unloading:key:16:physical::false', 'paired text does not escape owner disposal')
  f:nextBatch()
  lovr.textinput('é🙂', 233)
  expect.equal(
    f:trace(),
    'unloading:key:16:physical::false|native-text:é🙂',
    'the next batch recovers application text'
  )
  f:close()
end)

test('select-all consumes the physical command without inserting its paired text', function()
  local f = physical.boot()
  local selected = 0
  local target = f:localTarget('field', {
    key = function(event)
      if event.code == 30 and table.find(event.modifiers, 'control') then
        selected += 1
        return true
      end
      return false
    end,
  })
  expect.truthy(target:focus(), 'the field acquires focus')
  f:held 'lctrl'
  f:pair('a', 'a')
  f:held()
  lovr.textinput('stale', 115)
  expect.equal(selected, 1, 'one select-all command')
  expect.equal(f:trace(), 'field:key:30:physical:control:false', 'select-all and its batch insert no text')
  f:nextBatch()
  f:pair('q', 'q')
  expect.equal(
    f:trace(),
    'field:key:30:physical:control:false|field:key:16:physical::false|field:text:q',
    'typing resumes at the next update'
  )
  f:close()
end)

return test.result
