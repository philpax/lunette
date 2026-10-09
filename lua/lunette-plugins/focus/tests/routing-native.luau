-- Native source activations release every acquired mutation, including refused and raising inverses.
local testing = require '@testing'
local sourceModule = require '../source'
local expect = testing.expect
local test = testing.suite()

local function fixture(hooks, options)
  local fake = testing.native()
  hooks = hooks or {}
  local events = {}
  local seat = {
    dead = false,
    strokeFor = function(_self, value)
      events[#events + 1] = 'stroke:' .. value
      return { keycode = value == 'é' and 40 or 30, modifiers = { 'Shift' } }
    end,
  }
  local sink = { dead = false, domain = hooks.domain or 'window' }
  sink.modifiers = function(_self, modifiers)
    local event = 'mods:' .. table.concat(modifiers or {}, '+')
    events[#events + 1] = event
    if hooks.modifiers then
      return hooks.modifiers(event)
    end
    return true
  end
  sink.key = function(_self, code, pressed)
    local event = tostring(code) .. ':' .. tostring(pressed)
    events[#events + 1] = event
    if hooks.key then
      return hooks.key(event)
    end
    return true
  end
  sink.typeText = function(_self, value)
    events[#events + 1] = 'text:' .. value
    if hooks.text then
      return hooks.text(value)
    end
    return true
  end
  local snapshot = { handle = { dead = false }, target = { kind = 'native', seat = seat, sink = sink }, revision = 1 }
  local route = {
    snapshot = function()
      return snapshot
    end,
    keymapSeat = function()
      return seat
    end,
    blocked = function()
      return nil
    end,
    dispose = function() end,
  }
  local source, inverse = sourceModule.new({
    owns = function()
      return true
    end,
  }, {}, options, route)
  local function change()
    snapshot = { target = nil, handle = nil, revision = snapshot.revision + 1 }
    source:reset()
  end
  return {
    source = source,
    inverse = inverse,
    seat = seat,
    sink = sink,
    events = events,
    change = change,
    reports = fake.events.reported,
  }
end

test('native key delivery preserves modifiers and pairs key down with key up', function()
  local f = fixture()
  expect.equal(f.source:key({ code = 30, modifiers = { 'Control', 'Shift' } }).kind, 'consumed', 'native activation')
  expect.equal(table.concat(f.events, ','), 'mods:Control+Shift,30:true,30:false,mods:', 'the stroke and inverse')
  f.inverse()
end)

test('a failing native inverse is reported, every inverse runs, and later delivery is blocked', function()
  local f = fixture {
    key = function(event)
      return event ~= '30:true'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'refused', 'native key down refusal')
  expect.equal(table.concat(f.events, ','), 'mods:,30:true,30:false,mods:', 'all inverse mutations')
  f.inverse()
  f = fixture {
    key = function(event)
      if event == '30:false' then
        error 'key inverse error'
      end
      return true
    end,
    modifiers = function(event)
      if event == 'mods:' then
        error 'modifier inverse error'
      end
      return true
    end,
  }
  expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'failed', 'cleanup failure')
  expect.equal(table.concat(f.events, ','), 'mods:Shift,30:true,30:false,mods:', 'independent inverse attempts')
  expect.equal(#f.reports, 2, 'both cleanup errors are reported')
  local before = #f.events
  expect.equal(f.source:key({ code = 31 }).kind, 'failed', 'unsafe further delivery')
  expect.equal(#f.events, before, 'failed cleanup is never blindly retried')
  expect.equal(f.source:reset(), false, 'failed cleanup remains unsafe')
  expect.falsy(pcall(f.inverse), 'owner cleanup reports unsafe native state')
  local held = false
  f = fixture {
    modifiers = function(event)
      if event == 'mods:Shift' then
        held = true
        return true
      end
      return not held
    end,
  }
  expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'refused', 'modifier release refusal')
  expect.equal(f.source:key({ code = 31 }).kind, 'refused', 'blocked after refused cleanup')
  expect.falsy(f.source:reset(), 'reset cannot certify refused cleanup')
  expect.falsy(pcall(f.inverse), 'owner cleanup reports refused native release')
end)

test('a reentrant route transition releases input before public continuation and does not repeat cleanup', function()
  local f
  f = fixture {
    key = function(event)
      if event == '30:true' then
        f.change()
      end
      return true
    end,
  }
  expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'refused', 'route changed during delivery')
  expect.equal(table.concat(f.events, ','), 'mods:Shift,30:true,30:false,mods:', 'one immediate cleanup')
  f.inverse()
  expect.equal(#f.events, 4, 'disposal does not repeat completed inverses')
end)

test('window text resolves scalars while host text uses its native text operation and refuses on false', function()
  local f = fixture()
  expect.equal(f.source:text('aé').kind, 'consumed', 'window committed text')
  expect.equal(
    table.concat(f.events, ','),
    'stroke:a,mods:Shift,30:true,30:false,mods:,stroke:é,mods:Shift,40:true,40:false,mods:',
    'scalar strokes'
  )
  f.inverse()
  f = fixture { domain = 'host' }
  expect.equal(f.source:text('aé').kind, 'consumed', 'host committed text')
  expect.equal(table.concat(f.events, ','), 'text:aé', 'host text retains its native semantics')
  f.inverse()
  f = fixture {
    domain = 'host',
    text = function()
      return false
    end,
  }
  expect.equal(f.source:text('aé').kind, 'refused', 'host text refusal')
  expect.equal(#f.reports, 0, 'false is a result rather than a raised callback')
  f.inverse()
end)

test('one unrepresentable scalar refuses text rather than silently dropping it', function()
  local f = fixture()
  f.seat.strokeFor = function()
    return nil
  end
  expect.equal(f.source:text('🙂').kind, 'refused', 'unrepresentable scalar')
  expect.equal(#f.events, 0, 'no invented native activation')
  f.inverse()
end)

test('physical native printable keys await text while command chords deliver strokes', function()
  local f = fixture(nil, { mode = 'physical' })
  f.source:beginBatch(1)
  for _, modifiers in { {}, { 'Shift' }, { 'mod5' } } do
    expect.equal(
      f.source:key({ code = 30, modifiers = modifiers, batch = 1 }).kind,
      'unhandled',
      'printable activation'
    )
  end
  expect.equal(#f.events, 0, 'no duplicate native printable strokes')
  expect.equal(f.source:text('a', 1).kind, 'consumed', 'committed native text')
  expect.equal(f.source:key({ code = 30, modifiers = { 'Control' }, batch = 1 }).kind, 'consumed', 'command chord')
  f.inverse()
end)

test('physical keypad mode unavailable is a structured refusal rather than lost navigation', function()
  local f = fixture(nil, { mode = 'physical' })
  local result = f.source:key { code = 79 }
  expect.equal(result.kind, 'refused', 'unknown keypad mode')
  expect.truthy(result.message:find('modifier snapshot', 1, true), 'the missing event state is named')
  expect.equal(#f.events, 0, 'no guessed keypad activation or text')
  expect.equal(f.source:key({ code = 79, modifiers = { 'Control' } }).kind, 'consumed', 'known command chord')
  f.inverse()
end)

return test
