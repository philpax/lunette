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

return test.result
