local testing = require '@testing'
local lunette = require '@lunette'
local focus = require '@lunette-contracts/focus'
local expect = testing.expect
local test = testing.suite()

type InputSink = {
  dead: boolean,
  domain: 'window' | 'host',
  id: number,
  setModifiers: (InputSink, { lunette.ModifierName }) -> boolean,
  key: (InputSink, number, boolean) -> boolean,
  typeText: (InputSink, string) -> boolean,
}
type Fixture = {
  session: testing.Session,
  focus: focus.Service,
  owner: testing.Context,
  log: { string },
  seat: testing.Seat,
  native: focus.TargetHandle,
  field: (string) -> focus.TargetHandle,
}

local strokes: { [string]: lunette.Stroke } = {
  q = { keycode = 16, modifiers = {} },
  Q = { keycode = 16, modifiers = { 'shift' } },
}

local function boot(domain: 'window' | 'host'): Fixture
  local session = testing.boot { 'frame', 'focus', 'desktop/input' }
  local observed = session:observe(focus.capability)
  local f: Fixture = { session = session, focus = observed.service, owner = observed.context, log = {} }
  local function record(value: string)
    f.log[#f.log + 1] = value
  end
  f.seat = observed.context:resource(observed.context, function(): (testing.Seat, () -> ())
    local seat = lunette.newSeat { name = 'input-fixture' }
    return seat, function()
      seat:destroy()
    end
  end)
  f.seat.strokeFor = function(_self: testing.Seat, value: string): lunette.Stroke?
    local stroke = strokes[value]
    return stroke and { keycode = stroke.keycode, modifiers = table.clone(stroke.modifiers) }
  end
  f.native = f.focus:register(f.owner, {
    kind = 'native',
    seat = f.seat,
    sink = {
      dead = false,
      domain = domain,
      id = 701,
      setModifiers = function(_self: InputSink, modifiers: { lunette.ModifierName }): boolean
        record('mods:' .. table.concat(modifiers, '+'))
        return true
      end,
      key = function(_self: InputSink, code: number, down: boolean): boolean
        record('key:' .. code .. ':' .. (if down then 'down' else 'up'))
        return true
      end,
      typeText = function(_self: InputSink, text: string): boolean
        record('text:' .. text)
        return true
      end,
    },
  })
  f.field = function(label: string): focus.TargetHandle
    return f.focus:register(f.owner, {
      kind = 'local',
      keymapSeat = f.seat,
      wantsKeyboard = true,
      receiver = {
        key = function(event: focus.KeyEvent): boolean
          record(label .. ':key:' .. event.code .. ':' .. table.concat(event.modifiers, '+'))
          return false
        end,
        text = function(value: string): boolean
          record(label .. ':text:' .. value)
          return true
        end,
      },
    })
  end
  return f
end

-- Opens a batch, presses a key with the given keys held, commits its text, and returns what reached the route.
local function press(f: Fixture, held: { string }, key: string, text: string?): string
  f.session:update()
  table.clear(f.log)
  table.clear(f.session.native.events.held)
  for _, name in held do
    f.session.native.events.held[name] = true
  end
  lovr.keypressed(key, 0, false)
  if text then
    lovr.textinput(text, utf8.codepoint(text))
  end
  return table.concat(f.log, '|')
end

test('a focused native window receives each physical key once', function()
  local f = boot 'window'
  expect.truthy(f.native:focus(), 'the window acquires focus')
  expect.equal(press(f, {}, 'q', 'q'), 'mods:|key:16:down|key:16:up|mods:', 'a printable key')
  expect.equal(press(f, { 'lshift' }, 'q', 'Q'), 'mods:shift|key:16:down|key:16:up|mods:', 'a shifted key')
  expect.equal(press(f, { 'lctrl' }, 'q', 'q'), 'mods:control|key:16:down|key:16:up|mods:', 'a command chord')
  expect.equal(press(f, { 'lshift' }, 'left'), 'mods:shift|key:105:down|key:105:up|mods:', 'a navigation key')
end)

test('a focused host receives committed text whole and command chords as keys', function()
  local f = boot 'host'
  expect.truthy(f.native:focus(), 'the host acquires focus')
  expect.equal(press(f, { 'lshift' }, 'q', 'Qé🙂'), 'text:Qé🙂', 'the committed text')
  expect.equal(press(f, { 'lctrl' }, 'q', 'q'), 'mods:control|key:16:down|key:16:up|mods:', 'a command chord')
end)

test('a focused local receiver gets the key and its text once, and no text for a command chord', function()
  local f = boot 'window'
  expect.truthy(f.field('field'):focus(), 'the field acquires focus')
  expect.equal(press(f, { 'lshift' }, 'q', 'Qé'), 'field:key:16:shift|field:text:Qé', 'a printable key')
  expect.equal(press(f, { 'lctrl' }, 'q', 'q'), 'field:key:16:control', 'a command chord')
end)

test('text left in a batch when input is disabled does not reach a newly focused route', function()
  local f = boot 'host'
  local previous, replacement = f.field 'previous', f.field 'next'
  expect.truthy(previous:focus(), 'the original field acquires focus')
  expect.equal(press(f, {}, 'q'), 'previous:key:16:', 'the key reaches the original field')
  f.session.instances['desktop/input']:disable()
  expect.truthy(replacement:focus(), 'the replacement field acquires focus while input is disabled')
  f.session.instances['desktop/input']:enable()
  lovr.textinput('1', 49)
  expect.equal(#f.log, 1, 'the pending text is dropped')
  expect.equal(press(f, {}, 'q', '1'), 'next:key:16:|next:text:1', 'the next batch reaches the new route')
end)

return test
