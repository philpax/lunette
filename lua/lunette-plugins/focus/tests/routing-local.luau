-- Source delivery keeps the selected receiver and reports callback failures.
local testing = require '@testing'
local sourceModule = require '../source'
local expect = testing.expect
local test = testing.suite()

local function fixture(receiver, options)
  local fake = testing.native()
  local translations = {}
  local seat = {
    dead = false,
    characterFor = function(_self, code, modifiers)
      translations[#translations + 1] = { code, modifiers }
      return 'é'
    end,
  }
  local target = { kind = 'local', receiver = receiver, keymapSeat = seat, wantsKeyboard = true }
  local snapshot = { handle = { dead = false }, target = target, revision = 1, owner = 'receiver owner' }
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
  local owner = {}
  local context = {
    owns = function()
      return true
    end,
  }
  local source, inverse = sourceModule.new(context, owner, options, route)
  local function change(nextTarget)
    snapshot = { handle = { dead = false }, target = nextTarget, revision = snapshot.revision + 1 }
    source:reset()
  end
  return {
    source = source,
    inverse = inverse,
    seat = seat,
    translations = translations,
    change = change,
    reports = fake.events.reported,
  }
end

test('local key and text errors fail and are reported once each', function()
  local f = fixture {
    key = function()
      error 'receiver key failure'
    end,
    text = function()
      error 'text receiver failure'
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'failed', 'the receiver failure')
  expect.equal(#f.translations, 0, 'no translation after failure')
  local reports = f.reports
  expect.equal(#reports, 1, 'one reported callback failure')
  expect.truthy(reports[1].message:find('focus: receiver', 1, true), reports[1].message)
  expect.truthy(reports[1].message:find('source owner', 1, true), reports[1].message)
  expect.equal(f.source:text('aé').kind, 'failed', 'failed committed text')
  expect.equal(#reports, 2, 'text failure is reported once')
  f.inverse()
end)

test('virtual unhandled keys translate once with AltGr and physical keys never translate', function()
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
  expect.equal(f.source:key({ code = 30, modifiers = { 'shift' } }).kind, 'consumed', 'virtual fallback')
  expect.equal(#f.translations, 1, 'one live keymap lookup')
  expect.equal(texts[1], 'é', 'the complete character')
  f.inverse()
  f = fixture(receiver, { mode = 'physical' })
  expect.equal(f.source:key({ code = 30 }).kind, 'unhandled', 'physical activation')
  expect.equal(#f.translations, 0, 'physical keys do not translate')
  f.inverse()
  f = fixture(receiver)
  expect.equal(f.source:key({ code = 30, modifiers = { 'mod5' } }).kind, 'consumed', 'AltGr text fallback')
  expect.equal(f.translations[1][2][1], 'mod5', 'translation keeps requested modifiers')
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
  for _, modifiers in { { 'control' }, { 'logo' }, { 'alt' } } do
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
  for _, value in { string.char(0xff), string.char(0xc0, 0xaf), string.char(0xed, 0xa0, 0x80) } do
    expect.equal(f.source:text(value).kind, 'refused', 'invalid UTF-8')
  end
  expect.equal(#texts, 1, 'invalid text never reaches receiver')
  f.inverse()
end)

return test
