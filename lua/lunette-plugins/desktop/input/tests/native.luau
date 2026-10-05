local testing = require '@testing'
local physical = require './support/physical'
local expect = testing.expect
local test = physical.suite()

local function assertPair(f, held, key, text, wanted, isRepeat, modifiers)
  f:nextBatch()
  f:clear()
  f:held(unpack(held))
  f:pair(key, text, isRepeat, modifiers)
  expect.equal(f:trace(), wanted, 'the paired native delivery')
end

test('physical native printable and chord delivery once', function()
  local f = physical.boot()
  expect.truthy(f.nativeTarget:focus(), 'the application acquires focus')
  assertPair(f, {}, 'q', 'q', 'resolve:q|mods:|key:16:down|key:16:up|mods:')
  assertPair(f, { 'lshift' }, 'q', 'Q', 'resolve:Q|mods:shift|key:16:down|key:16:up|mods:')
  assertPair(f, { 'ralt' }, 'e', '€', 'resolve:€|mods:mod5|key:18:down|key:18:up|mods:')
  assertPair(f, { 'lctrl' }, 'q', 'q', 'mods:control|key:16:down|key:16:up|mods:')
  assertPair(f, { 'lgui' }, 'q', 'q', 'mods:logo|key:16:down|key:16:up|mods:')
  assertPair(f, { 'lalt' }, 'q', 'q', 'mods:alt|key:16:down|key:16:up|mods:')
  assertPair(f, { 'lctrl', 'lshift' }, 'q', 'Q', 'mods:control+shift|key:16:down|key:16:up|mods:')
  assertPair(f, {}, 'q', 'q', 'resolve:q|mods:|key:16:down|key:16:up|mods:', true)
  assertPair(
    f,
    {},
    'q',
    'é🙂',
    'resolve:é|mods:|key:40:down|key:40:up|mods:|resolve:🙂|mods:mod5+shift|key:57:down|key:57:up|mods:'
  )
  assertPair(f, { 'lshift' }, 'left', nil, 'mods:shift|key:105:down|key:105:up|mods:')
  f:close()
end)

test('host printable input uses whole committed text and never a second mapped activation', function()
  local f = physical.boot 'host'
  expect.truthy(f.nativeTarget:focus(), 'the host acquires focus')
  assertPair(f, { 'lshift' }, 'q', 'Qé🙂', 'native-text:Qé🙂')
  assertPair(f, { 'ralt' }, 'e', '€', 'native-text:€')
  assertPair(f, { 'lctrl' }, 'q', 'q', 'mods:control|key:16:down|key:16:up|mods:')
  f:close()
end)

test('native keypad navigation without committed text reaches window and host targets', function()
  for _, domain in { 'window', 'host' } do
    local f = physical.boot(domain)
    expect.truthy(f.nativeTarget:focus(), 'the native route acquires focus')
    assertPair(f, {}, 'kp1', nil, 'mods:|key:79:down|key:79:up|mods:', false, physical.modifiers())
    assertPair(f, {}, 'kp.', nil, 'mods:shift|key:83:down|key:83:up|mods:', false, physical.modifiers { shift = true })
    assertPair(
      f,
      {},
      'kp1',
      nil,
      'mods:shift+numLock|key:79:down|key:79:up|mods:',
      false,
      physical.modifiers { shift = true, numLock = true }
    )
    f:close()
  end
end)

test('numeric keypad digits and decimal use committed text exactly once', function()
  for _, domain in { 'window', 'host' } do
    local f = physical.boot(domain)
    expect.truthy(f.nativeTarget:focus(), 'the native route acquires focus')
    for _, pair in { { 'kp1', '1', 2 }, { 'kp.', '.', 52 } } do
      local wanted = if domain == 'host'
        then 'native-text:' .. pair[2]
        else 'resolve:' .. pair[2] .. '|mods:|key:' .. pair[3] .. ':down|key:' .. pair[3] .. ':up|mods:'
      assertPair(f, { 'lshift' }, pair[1], pair[2], wanted, false, physical.modifiers { numLock = true })
    end
    f:close()
  end
end)

test('a snapshot with Alt preserves right Alt committed text rather than a command stroke', function()
  for _, domain in { 'window', 'host' } do
    local f = physical.boot(domain)
    expect.truthy(f.nativeTarget:focus(), 'the native route acquires focus')
    assertPair(
      f,
      { 'ralt' },
      'e',
      '€',
      if domain == 'host' then 'native-text:€' else 'resolve:€|mods:mod5|key:18:down|key:18:up|mods:',
      false,
      physical.modifiers { alt = true }
    )
    f:close()
  end
end)

test('event command modifiers win over later held-key polling and deliver one keypad stroke', function()
  local f = physical.boot()
  expect.truthy(f.nativeTarget:focus(), 'the application acquires focus')
  assertPair(
    f,
    {},
    'kp1',
    '1',
    'mods:control+numLock|key:79:down|key:79:up|mods:',
    false,
    physical.modifiers { control = true, numLock = true }
  )
  assertPair(f, { 'lctrl' }, 'q', nil, '', false, physical.modifiers())
  f:close()
end)

test('unsupported key names do not guess an evdev code from the scancode', function()
  local f = physical.boot()
  expect.truthy(f.nativeTarget:focus(), 'the application acquires focus')
  f:held 'lctrl'
  lovr.keypressed('unsupported', 16, false)
  expect.equal(f:trace(), '', 'unsupported physical input never reaches the native sink')
  f:close()
end)

test('native key and text failures report at the source and never masquerade as unhandled input', function()
  local f = physical.boot 'host'
  expect.truthy(f.nativeTarget:focus(), 'the host acquires focus')
  local fallthrough = 0
  f.frame:onKey(f.frameOwner, {
    phase = 'delivery',
    order = 100,
    run = function()
      fallthrough += 1
    end,
  })
  f.frame:onText(f.frameOwner, {
    phase = 'delivery',
    order = 100,
    run = function()
      fallthrough += 1
    end,
  })
  f.hooks.key = function(_code, down)
    if down then
      error 'native press failure'
    end
    return true
  end
  f:held 'lctrl'
  f:pair('q', 'q')
  expect.equal(f:trace(), 'mods:control|key:16:down|key:16:up|mods:', 'failed native press releases its stroke')
  expect.equal(fallthrough, 0, 'failed delivery is not unhandled')
  local reports = f.native.events.reported
  expect.equal(#reports, 1, 'one native press diagnostic')
  expect.truthy(reports[1].message:find('focus: source owner', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('press key', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('native press failure', 1, true), reports[1].message)
  table.clear(reports)
  f.hooks.key = nil
  f.hooks.text = function()
    error 'native committed text failure'
  end
  f:nextBatch()
  f:clear()
  f:held()
  lovr.textinput('é🙂', 233)
  expect.equal(f:trace(), 'native-text:é🙂', 'one failed whole-string native operation')
  expect.equal(fallthrough, 0, 'failed committed text is not unhandled')
  expect.equal(#reports, 1, 'one native text diagnostic')
  expect.truthy(reports[1].message:find('focus: source owner', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('native committed text failure', 1, true), reports[1].message)
  table.clear(reports)
  f.hooks.text = nil
  f:close()
end)

test('a refused native activation never falls through to another delivery handler', function()
  local f = physical.boot()
  expect.truthy(f.nativeTarget:focus(), 'the application acquires focus')
  local fallthrough = 0
  f.frame:onKey(f.frameOwner, {
    phase = 'delivery',
    order = 100,
    run = function()
      fallthrough += 1
    end,
  })
  f.hooks.key = function(_code, down)
    return not down
  end
  f:held 'lctrl'
  f:pair('q', 'q')
  expect.equal(f:trace(), 'mods:control|key:16:down|key:16:up|mods:', 'refused press still attempts inverses')
  expect.equal(fallthrough, 0, 'refusal is not unhandled')
  f:close()
end)

return test.result
