-- Source delivery keeps the selected receiver and reports callback failures without native fallback.
local testing = require '@testing'
local sourceModule = require '../source'
local expect = testing.expect
local test = testing.suite()

local function fixture(receiver, options)
  local fake = testing.native()
  local nativeCalls, translations, listeners = {}, {}, {}
  local seat = {
    dead = false,
    characterFor = function(_self, code, modifiers)
      translations[#translations + 1] = { code, modifiers }
      return 'é'
    end,
  }
  local sink = {
    dead = false,
    domain = 'host',
    modifiers = function()
      nativeCalls[#nativeCalls + 1] = 'modifiers'
      return true
    end,
    key = function()
      nativeCalls[#nativeCalls + 1] = 'key'
      return true
    end,
    typeText = function()
      nativeCalls[#nativeCalls + 1] = 'text'
      return true
    end,
  }
  local target = { kind = 'local', receiver = receiver, keymapSeat = seat, wantsKeyboard = true }
  local snapshot = { handle = { dead = false }, target = target, revision = 1, owner = 'receiver owner' }
  local route = {
    snapshot = function()
      return snapshot
    end,
    reconcile = function()
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
  local owner = {}
  local context = {
    owns = function()
      return true
    end,
  }
  local source, inverse = sourceModule.new(context, owner, options, route)
  local function change(nextTarget)
    snapshot = { handle = { dead = false }, target = nextTarget, revision = snapshot.revision + 1 }
    for _, run in table.clone(listeners) do
      run()
    end
  end
  return {
    source = source,
    inverse = inverse,
    seat = seat,
    sink = sink,
    nativeCalls = nativeCalls,
    translations = translations,
    change = change,
    listeners = listeners,
    reports = fake.events.reported,
  }
end

test('a local key error fails once and never reaches native input', function()
  local f = fixture {
    key = function()
      error 'receiver key failure'
    end,
    text = function()
      error 'not reached'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'failed', 'the receiver failure')
  expect.equal(#f.translations, 0, 'no translation after failure')
  expect.equal(#f.nativeCalls, 0, 'no native fallback')
  local reports = f.reports
  expect.equal(#reports, 1, 'one reported callback failure')
  expect.truthy(reports[1].message:find('focus: receiver', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('source owner', 1, true), reports[1].message)
  f.inverse()
end)

test('virtual unhandled keys translate once and physical keys never translate', function()
  local texts = {}
  local receiver = {
    key = function()
      return false
    end,
    text = function(value)
      texts[#texts + 1] = value
      return true
    end,
  }
  local f = fixture(receiver)
  expect.equal(f.source:key({ code = 30, modifiers = { 'Shift' } }).kind, 'consumed', 'virtual fallback')
  expect.equal(#f.translations, 1, 'one live keymap lookup')
  expect.equal(texts[1], 'é', 'the complete character')
  f.inverse()
  f = fixture(receiver, { mode = 'physical' })
  expect.equal(f.source:key({ code = 30 }).kind, 'unhandled', 'physical activation')
  expect.equal(#f.translations, 0, 'physical keys do not translate')
  f.inverse()
end)

test('shortcut modifiers and translated controls never enter local text', function()
  local count = 0
  local f = fixture {
    key = function()
      return false
    end,
    text = function()
      count += 1
      return true
    end,
  }
  for _, modifiers in { { 'Control' }, { 'Logo' }, { 'Mod4' }, { 'Mod1' } } do
    expect.equal(f.source:key({ code = 30, modifiers = modifiers }).kind, 'unhandled', 'shortcut remains a key')
  end
  expect.equal(#f.translations, 0, 'shortcuts do not translate')
  for _, character in { '\0', '\n', utf8.char(0x7f), utf8.char(0x85) } do
    f.seat.characterFor = function()
      return character
    end
    expect.equal(f.source:key({ code = 30 }).kind, 'unhandled', 'control remains a key')
  end
  expect.equal(count, 0, 'no control text')
  f.inverse()
end)

test('a route changed inside an unhandled key cannot redirect its text continuation', function()
  local replacementCalls = 0
  local f
  f = fixture {
    key = function()
      f.change {
        kind = 'local',
        receiver = {
          key = function()
            return false
          end,
          text = function()
            replacementCalls += 1
            return true
          end,
        },
        wantsKeyboard = true,
      }
      return false
    end,
    text = function()
      error 'old text continuation'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'refused', 'the stale operation')
  expect.equal(#f.translations, 0, 'no stale keymap lookup')
  expect.equal(replacementCalls, 0, 'no delivery to a replacement')
  f.inverse()
end)

test('local text receives the full valid string once and invalid UTF-8 is refused', function()
  local texts = {}
  local f = fixture {
    key = function()
      return false
    end,
    text = function(value)
      texts[#texts + 1] = value
      return false
    end,
  }
  expect.equal(f.source:text('aé🙂').kind, 'unhandled', 'receiver refusal is unhandled')
  expect.equal(#texts, 1, 'one committed text callback')
  expect.equal(texts[1], 'aé🙂', 'the full UTF-8 string')
  expect.equal(f.source:text(string.char(0xff)).kind, 'refused', 'invalid UTF-8')
  expect.equal(#texts, 1, 'invalid text never reaches receiver')
  f.inverse()
end)

test('disposing a source during its key callback forbids any continuation', function()
  local f
  f = fixture {
    key = function()
      f.inverse()
      return false
    end,
    text = function()
      error 'text after disposal'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'refused', 'disposal ends the operation')
  expect.truthy(f.source.dead, 'the source is dead')
  expect.equal(#f.listeners, 0, 'the route listener is released')
  expect.equal(f.source:text('later').kind, 'refused', 'dead source text')
end)

test('explicit destruction disposes the provider after source state clears', function()
  testing.native()
  local source, inverse
  local released = 0
  local route = {
    snapshot = function()
      return { revision = 1 }
    end,
    reconcile = function()
      return false
    end,
    keymapSeat = function()
      return nil
    end,
    listen = function()
      return function()
        expect.truthy(source.dead, 'state clears before listener release')
      end
    end,
    dispose = function()
      expect.truthy(source.dead, 'state clears before provider release')
      released += 1
      inverse()
    end,
  }
  source, inverse = sourceModule.new({
    owns = function()
      return true
    end,
  }, {}, nil, route)
  expect.truthy(source:destroy(), 'explicit destruction succeeds')
  expect.equal(released, 1, 'one provider disposal')
  inverse()
  expect.falsy(source:destroy(), 'repeated destruction is inert')
  expect.equal(released, 1, 'no repeated provider disposal')
end)

test('a local route never executes the subordinate native target callback', function()
  local f = fixture({
    key = function()
      return false
    end,
    text = function()
      return true
    end,
  }, {
    nativeTarget = function()
      error 'native override must be subordinate'
    end,
  })
  expect.equal(f.source:key({ code = 30 }).kind, 'consumed', 'the local receiver gets translated text')
  expect.equal(f.source:text('local').kind, 'consumed', 'the local receiver gets committed text')
  expect.equal(#f.reports, 0, 'no native override callback')
  f.inverse()
end)

test('local text errors are reported without native fallback', function()
  local f = fixture {
    key = function()
      return false
    end,
    text = function()
      error 'text receiver failure'
    end,
  }
  expect.equal(f.source:text('aé').kind, 'failed', 'failed committed text')
  expect.equal(#f.reports, 1, 'text failure is reported once')
  expect.equal(#f.nativeCalls, 0, 'no text fallback to native input')
  f.inverse()
end)

test('AltGr can translate local virtual keys and receiver modifiers cannot mutate translation', function()
  local f = fixture {
    key = function(event)
      expect.equal(event.modifiers[1], 'mod5', 'AltGr reaches the receiver')
      expect.falsy(
        pcall(function()
          event.modifiers[1] = 'control'
        end),
        'the receiver event is immutable'
      )
      return false
    end,
    text = function()
      return true
    end,
  }
  expect.equal(f.source:key({ code = 30, modifiers = { 'mod5' } }).kind, 'consumed', 'AltGr text fallback')
  expect.equal(f.translations[1][2][1], 'mod5', 'translation keeps requested modifiers')
  f.inverse()
end)

test('invalid UTF-8 forms never reach local text', function()
  local f = fixture {
    key = function()
      return false
    end,
    text = function()
      error 'invalid text reached receiver'
    end,
  }
  for _, value in
    {
      string.char(0x80),
      string.char(0xc0, 0xaf),
      string.char(0xe2, 0x82),
      string.char(0xed, 0xa0, 0x80),
      string.char(0xf4, 0x90, 0x80, 0x80),
    }
  do
    expect.equal(f.source:text(value).kind, 'refused', 'invalid UTF-8')
  end
  expect.equal(#f.reports, 0, 'invalid text is refused before callbacks')
  f.inverse()
end)

test('unresolved provider native focus cleanup blocks every source callback', function()
  testing.native()
  local source, inverse = sourceModule.new({
    owns = function()
      return true
    end,
  }, {}, {
    nativeTarget = function()
      error 'blocked native callback'
    end,
  }, {
    blocked = function()
      return { kind = 'refused', message = 'native focus cleanup is unresolved' }
    end,
    snapshot = function()
      error 'blocked route selection'
    end,
    reconcile = function()
      error 'blocked native reconciliation'
    end,
    keymapSeat = function()
      return nil
    end,
    listen = function()
      return function() end
    end,
  })
  expect.equal(source:key({ code = 30 }).kind, 'refused', 'blocked key')
  expect.equal(source:text('local').kind, 'refused', 'blocked text')
  inverse()
end)

return test
