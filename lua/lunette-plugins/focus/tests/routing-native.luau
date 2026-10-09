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
      return { keycode = value == 'é' and 40 or 30, modifiers = { 'shift' } }
    end,
  }
  local sink = { dead = false, domain = hooks.domain or 'window' }
  sink.setModifiers = function(_self, modifiers)
    local event = 'mods:' .. table.concat(modifiers or {}, '+')
    events[#events + 1] = event
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
  return {
    source = source,
    inverse = inverse,
    seat = seat,
    sink = sink,
    events = events,
    reports = fake.events.reported,
  }
end

test('native key delivery preserves modifiers and pairs key down with key up', function()
  local f = fixture()
  expect.equal(f.source:key({ code = 30, modifiers = { 'control', 'shift' } }).kind, 'consumed', 'native activation')
  expect.equal(table.concat(f.events, ','), 'mods:control+shift,30:true,30:false,mods:', 'the stroke and inverse')
  f.inverse()
end)

test('a refused key down still releases everything it acquired', function()
  local f = fixture {
    key = function(event)
      return event ~= '30:true'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'refused', 'native key down refusal')
  expect.equal(table.concat(f.events, ','), 'mods:,30:true,30:false,mods:', 'all inverse mutations')
  f.inverse()
end)

test('a failed native release blocks further delivery', function()
  local f = fixture {
    key = function(event)
      if event == '30:false' then
        error 'key inverse error'
      end
      return true
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'failed', 'cleanup failure')
  expect.equal(#f.reports, 1, 'the cleanup error is reported')
  local before = #f.events
  expect.equal(f.source:key({ code = 31 }).kind, 'failed', 'unsafe further delivery')
  expect.equal(#f.events, before, 'failed cleanup is never blindly retried')
  expect.falsy(pcall(f.inverse), 'owner cleanup reports unsafe native state')
end)

test(
  'window text becomes key strokes, host text uses its native operation, and unrepresentable text is refused',
  function()
    local f = fixture()
    expect.equal(f.source:text('aé').kind, 'consumed', 'window committed text')
    expect.equal(
      table.concat(f.events, ','),
      'stroke:a,mods:shift,30:true,30:false,mods:,stroke:é,mods:shift,40:true,40:false,mods:',
      'scalar strokes'
    )
    f.inverse()
    f = fixture()
    f.seat.strokeFor = function()
      return nil
    end
    expect.equal(f.source:text('🙂').kind, 'refused', 'an unrepresentable scalar')
    expect.equal(#f.events, 0, 'no invented native activation')
    f.inverse()
    f = fixture { domain = 'host' }
    expect.equal(f.source:text('aé').kind, 'consumed', 'host committed text')
    expect.equal(table.concat(f.events, ','), 'text:aé', 'host text keeps its native semantics')
    f.inverse()
  end
)

test('physical native printable keys await text while command chords deliver strokes', function()
  local f = fixture(nil, { mode = 'physical' })
  f.source:beginBatch(1)
  expect.equal(f.source:key({ code = 30, modifiers = { 'shift' }, batch = 1 }).kind, 'unhandled', 'printable key')
  expect.equal(#f.events, 0, 'no duplicate native printable strokes')
  expect.equal(f.source:text('a', 1).kind, 'consumed', 'committed native text')
  expect.equal(f.source:key({ code = 30, modifiers = { 'control' }, batch = 1 }).kind, 'consumed', 'command chord')
  f.inverse()
end)

return test
