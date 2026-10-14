local testing = require '@testing'
local sourceModule = require '../private/source'
local expect = testing.expect
local test = testing.suite()

type KeyEvent = {
  read code: number,
  read modifiers: { read [number]: string },
  read source: 'virtual' | 'physical',
  read isRepeat: boolean,
}
type Receiver = { read key: (KeyEvent) -> boolean, read text: (string) -> boolean }
type Seat = { dead: boolean, characterFor: (Seat, number, { read [number]: string }) -> string? }
type Target = { read kind: 'local', read receiver: Receiver, read keymapSeat: Seat?, read wantsKeyboard: boolean }
type Snapshot = { read handle: { read dead: boolean }, read target: Target, read revision: number, read owner: string? }
type Options = { read mode: ('virtual' | 'physical')? }
type Translation = { [number]: number | { read [number]: string } }
type Result = { read kind: 'consumed' | 'unhandled' | 'refused' | 'failed', read message: string? }
type Source = {
  read key: (Source, { read code: number, read modifiers: { read [number]: string }?, read batch: number? }) -> Result,
  read text: (Source, string, number?) -> Result,
  read beginBatch: (Source, number) -> (),
  read reset: (Source) -> boolean,
}
type Fixture = {
  source: Source,
  inverse: () -> (),
  seat: Seat,
  translations: { Translation },
  change: (Target) -> (),
  reports: typeof(testing.native().events.reported),
}

local function fixture(receiver: Receiver, options: Options?): Fixture
  local fake = testing.native()
  local translations: { Translation } = {}
  local seat = {
    dead = false,
    characterFor = function(_self: Seat, code: number, modifiers: { read [number]: string }): string
      translations[#translations + 1] = { code, modifiers }
      return 'é'
    end,
  }
  local target = { kind = 'local', receiver = receiver, keymapSeat = seat, wantsKeyboard = true }
  local snapshot: Snapshot = { handle = { dead = false }, target = target, revision = 1, owner = 'receiver owner' }
  local route = {
    snapshot = function(): Snapshot
      return snapshot
    end,
    keymapSeat = function(): Seat
      return seat
    end,
    blocked = function(): nil
      return nil
    end,
    dispose = function() end,
  }
  local owner = {}
  local context = {
    owns = function(): boolean
      return true
    end,
  }
  local source, inverse = sourceModule.new(context, owner, options, route)
  local function change(nextTarget: Target)
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

local function recorder(key: ((KeyEvent) -> boolean)?): ({ string }, Receiver)
  local texts: { string } = {}
  return texts,
    {
      key = key or function(): boolean
        return false
      end,
      text = function(value: string): boolean
        texts[#texts + 1] = value
        return true
      end,
    }
end

test('an unhandled virtual key translates through the keymap with its modifiers', function()
  local texts, receiver = recorder()
  local f = fixture(receiver)
  expect.equal(f.source:key({ code = 30, modifiers = { 'mod5' } }).kind, 'consumed', 'AltGr text fallback')
  expect.equal(f.translations[1][2][1], 'mod5', 'translation keeps the modifiers')
  expect.equal(texts[1], 'é', 'the complete character')
  f.inverse()
end)

test('shortcut modifiers and translated controls never enter local text', function()
  local texts, receiver = recorder()
  local f = fixture(receiver)
  for _, modifiers in { { 'control' }, { 'logo' }, { 'alt' } } do
    expect.equal(f.source:key({ code = 30, modifiers = modifiers }).kind, 'unhandled', 'shortcut remains a key')
  end
  f.seat.characterFor = function(): string
    return '\n'
  end
  expect.equal(f.source:key({ code = 30 }).kind, 'unhandled', 'a control character remains a key')
  expect.equal(#texts, 0, 'no shortcut or control text')
  f.inverse()
end)

test('local text receives the full valid string once and invalid UTF-8 is refused', function()
  local texts, receiver = recorder()
  local f = fixture(receiver)
  expect.equal(f.source:text('aé🙂').kind, 'consumed', 'valid text')
  expect.equal(texts[1], 'aé🙂', 'the full UTF-8 string')
  expect.equal(f.source:text(string.char(0xc0, 0xaf)).kind, 'refused', 'invalid UTF-8')
  expect.equal(#texts, 1, 'invalid text never reaches the receiver')
  f.inverse()
end)

test('a receiver error fails the delivery and is reported', function()
  local f = fixture {
    key = function(): never
      error 'receiver key failure'
    end,
    text = function(): boolean
      return true
    end,
  }
  expect.equal(f.source:key({ code = 30 }).kind, 'failed', 'the receiver failure')
  expect.equal(#f.reports, 1, 'one reported callback failure')
  expect.truthy(f.reports[1].message:find('receiver key failure', 1, true), f.reports[1].message)
  f.inverse()
end)

test('physical text is bound to the batch and route it began with', function()
  local texts, receiver = recorder()
  local f = fixture(receiver, { mode = 'physical' })
  expect.equal(f.source:key({ code = 30 }).kind, 'unhandled', 'physical keys do not translate')
  expect.equal(#f.translations, 0, 'no keymap lookup')
  expect.equal(f.source:text('unbound', 1).kind, 'refused', 'no begun batch')
  f.source:beginBatch(1)
  f.change { kind = 'local', receiver = receiver, wantsKeyboard = true }
  expect.equal(f.source:text('stale', 1).kind, 'refused', 'text after a binding changed the route')
  f.source:beginBatch(2)
  expect.equal(f.source:text('old', 1).kind, 'refused', 'an old batch')
  expect.equal(f.source:text('current', 2).kind, 'consumed', 'the current batch')
  expect.equal(table.concat(texts, ','), 'current', 'only current batch text')
  f.inverse()
end)

test('a consumed physical key suppresses the text of its batch', function()
  local texts, receiver = recorder(function(): boolean
    return true
  end)
  local f = fixture(receiver, { mode = 'physical' })
  f.source:beginBatch(4)
  expect.equal(f.source:key({ code = 30, batch = 4 }).kind, 'consumed', 'the binding consumes its key')
  expect.equal(f.source:text('a', 4).kind, 'refused', 'text of the same batch')
  f.source:beginBatch(5)
  expect.equal(f.source:text('c', 5).kind, 'consumed', 'fresh batch text')
  expect.equal(table.concat(texts, ','), 'c', 'no consumed-key duplicates')
  f.inverse()
end)

return test
