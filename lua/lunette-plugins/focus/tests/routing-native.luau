-- Native source activations release every acquired mutation, including refused and raising inverses.
local testing = require '@testing'
local sourceModule = require '../source'
local expect = testing.expect
local test = testing.suite()

local function fixture(hooks, options)
  local fake = testing.native()
  hooks = hooks or {}
  local events, listeners = {}, {}
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
    reconcile = function()
      events[#events + 1] = 'reconcile'
      return true
    end,
    keymapSeat = function()
      return seat
    end,
    listen = function(run)
      listeners[#listeners + 1] = run
      return function()
        table.remove(listeners, table.find(listeners, run))
      end
    end,
  }
  local source, inverse = sourceModule.new({
    owns = function()
      return true
    end,
  }, {}, options, route)
  local function change()
    snapshot = { target = nil, handle = nil, revision = snapshot.revision + 1 }
    for _, run in table.clone(listeners) do
      run()
    end
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

test('false key down is refused and still attempts key up and modifier release', function()
  local f = fixture {
    key = function(event)
      return event ~= '30:true'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'refused', 'native refusal')
  expect.equal(table.concat(f.events, ','), 'mods:,30:true,30:false,mods:', 'all inverse mutations')
  f.inverse()
end)

test('raising key up does not prevent modifier release and blocks further delivery', function()
  local f = fixture {
    key = function(event)
      if event == '30:false' then
        error 'release failure'
      end
      return true
    end,
  }
  expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'failed', 'inverse failure')
  expect.equal(
    table.concat(f.events, ','),
    'mods:Shift,30:true,30:false,mods:',
    'modifier release after key release failure'
  )
  local before = #f.events
  expect.equal(f.source:key({ code = 31 }).kind, 'failed', 'unsafe further delivery')
  expect.equal(#f.events, before, 'failed cleanup is never blindly retried')
  expect.equal(f.source:reset(), false, 'failed cleanup remains unsafe')
  local reports = f.reports
  expect.equal(#reports, 1, 'inverse error reported')
  expect.falsy(pcall(f.inverse), 'owner cleanup reports unsafe native state')
end)

test('false modifier release blocks subsequent delivery without hiding refusal', function()
  local held = false
  local f = fixture {
    modifiers = function(event)
      if event == 'mods:Shift' then
        held = true
        return true
      end
      return not held
    end,
  }
  expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'refused', 'cleanup refusal')
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

test('window text resolves scalars while host text uses its native text operation', function()
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

test('native delivery keeps an omitted seat and reverse text uses only the default keymap', function()
  testing.native()
  local lunette = require '@lunette'
  local delivered, lookedUp = {}, 0
  local seat = {
    dead = false,
    strokeFor = function()
      lookedUp += 1
      return { keycode = 30, modifiers = {} }
    end,
  }
  lunette.defaultSeat = function()
    return seat
  end
  local sink = { dead = false, domain = 'window', id = 7 }
  sink.modifiers = function(_self, _modifiers, deliverySeat)
    delivered[#delivered + 1] = deliverySeat == nil
    return true
  end
  sink.key = function(_self, _code, _pressed, deliverySeat)
    delivered[#delivered + 1] = deliverySeat == nil
    return true
  end
  local snapshot = { handle = { dead = false }, target = { kind = 'native', sink = sink }, revision = 1 }
  local source, inverse = sourceModule.new(
    {
      owns = function()
        return true
      end,
    },
    {},
    nil,
    {
      snapshot = function()
        return snapshot
      end,
      reconcile = function()
        return false
      end,
      keymapSeat = function()
        error 'recent keymap seat is not the native delivery default'
      end,
      listen = function()
        return function() end
      end,
    }
  )
  expect.equal(source:key({ code = 30 }).kind, 'consumed', 'nil-seat key')
  expect.equal(source:text('a').kind, 'consumed', 'nil-seat text')
  expect.equal(lookedUp, 1, 'default keymap lookup')
  for _, omitted in delivered do
    expect.truthy(omitted, 'seat omission is preserved')
  end
  inverse()
end)

test('native override accepts replacement wrappers with the same stable identities', function()
  testing.native()
  local seat = { id = 2, dead = false }
  local sink = { id = 9, domain = 'window', dead = false }
  local calls = 0
  local currentSink = {
    id = 9,
    domain = 'window',
    dead = false,
    key = function()
      calls += 1
      return true
    end,
    modifiers = function()
      return true
    end,
  }
  local snapshot = { revision = 1 }
  local source, inverse = sourceModule.new({
    owns = function()
      return true
    end,
  }, {}, {
    nativeTarget = function()
      return seat, sink
    end,
  }, {
    snapshot = function()
      return snapshot
    end,
    reconcile = function()
      snapshot = {
        handle = { dead = false },
        target = { kind = 'native', seat = { id = 2, dead = false }, sink = currentSink },
        revision = 2,
      }
      return true
    end,
    keymapSeat = function()
      return nil
    end,
    listen = function()
      return function() end
    end,
  })
  expect.equal(source:key({ code = 30 }).kind, 'consumed', 'stable identity selection')
  expect.equal(calls, 2, 'key down and key up use the selected current wrapper')
  inverse()
end)

test('each failing native inverse is reported and later inverses still run', function()
  local f = fixture {
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
  expect.falsy(pcall(f.inverse), 'unsafe source cleanup raises')
end)

test('host native text false is refused rather than reported as consumed', function()
  local f = fixture {
    domain = 'host',
    text = function()
      return false
    end,
  }
  expect.equal(f.source:text('aé').kind, 'refused', 'host text refusal')
  expect.equal(#f.reports, 0, 'false is a result rather than a raised callback')
  f.inverse()
end)

for _, ending in { 'destroy', 'inverse' } do
  test(
    'source ' .. ending .. ' during native key down releases independent inverses before provider cleanup',
    function()
      local f
      f = fixture {
        key = function(event)
          if event == '30:true' then
            if ending == 'destroy' then
              expect.truthy(f.source:destroy(), 'destruction during native delivery')
            else
              f.inverse()
            end
          end
          return true
        end,
      }
      expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'refused', 'destroyed operation')
      expect.equal(table.concat(f.events, ','), 'mods:Shift,30:true,30:false,mods:', 'independent native inverses')
      expect.truthy(f.source.dead, 'the retained source is dead')
      f.inverse()
      expect.equal(#f.events, 4, 'the owner inverse does not repeat cleanup')
    end
  )
end

return test
