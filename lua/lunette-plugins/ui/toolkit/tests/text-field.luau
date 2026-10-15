local testing = require '@testing'
local lunette = require '@lunette'
local keys = require '@lunette-contracts/keys'
local edit = require '../private/text/text-edit'
local fixture = require './support/text-field'
local expect = testing.expect
local test = testing.suite()
local codes = keys.CODES

-- Reads the caret and anchor through the visual a draw hook receives.
local function selection(field: fixture.Fixture): (number?, number?)
  local visual = field.snapshot()
  return visual.caret, visual.anchor
end

local clusters = {
  'a',
  'é',
  '界',
  'e' .. utf8.char(0x301),
  utf8.char(0x1f44d, 0x1f3fd),
  utf8.char(0x1f1ec, 0x1f1e7),
  utf8.char(0x1f469, 0x200d, 0x1f4bb),
  utf8.char(0x1100, 0x1161, 0x11a8),
  utf8.char(0x915, 0x94d, 0x937),
}

test('uses real native extended grapheme boundaries for representative clusters', function()
  expect.equal(table.concat(lunette.textBoundaries '', ','), '1')
  for _, cluster in clusters do
    expect.equal(table.concat(lunette.textBoundaries(cluster), ','), '1,' .. tostring(#cluster + 1), cluster)
    local state = edit.new('x' .. cluster .. 'y')
    state = edit.select(state, #state.value, #state.value)
    local backward = edit.erase(state, 'backward')
    expect.equal(backward.value, 'xy', 'Backspace removes one whole cluster')
    state = edit.select(state, 2, 2)
    local forward = edit.erase(state, 'forward')
    expect.equal(forward.value, 'xy', 'Delete removes one whole cluster')
  end
end)

test('rejects malformed UTF-8 and unsupported single-line content atomically', function()
  local field = fixture.new { value = 'draft' }
  field.receiver.key(fixture.key(codes.home))
  field.receiver.key(fixture.key(codes.right))
  field.receiver.key(fixture.key(codes.right, { 'shift' }))
  local changes = field.state.changes
  for _, invalid in
    {
      string.char(255),
      string.char(0xed, 0xa0, 0x80),
      '\n',
      '\0',
      utf8.char(0x2028),
    }
  do
    expect.raises(function()
      field.receiver.text(invalid)
    end, 'text field:')
    expect.equal(field.field:value(), 'draft')
    local caret, anchor = selection(field)
    expect.equal(caret, 3)
    expect.equal(anchor, 2)
    expect.raises(function()
      field.field:setValue(invalid)
    end, 'text field:')
  end
  expect.equal(field.state.changes, changes, 'rejected edits do not publish changes')
end)

test('routes evdev editing commands while printable activations never insert text', function()
  local field = fixture.new { value = 'abc' }
  expect.equal(field.widget.wantsKeyboard, true)
  expect.equal(field.receiver.key(fixture.key(codes.a)), false)
  expect.equal(field.field:value(), 'abc')
  expect.equal(field.receiver.key(fixture.key(codes.a, { 'control' })), true)
  expect.equal(field.receiver.text '界', true)
  expect.equal(field.field:value(), '界')
  field.receiver.key(fixture.key(codes.home))
  field.receiver.key(fixture.key(codes.right, { 'shift' }, 'physical'))
  local caret, anchor = selection(field)
  expect.equal(caret, #field.field:value() + 1)
  expect.equal(anchor, 1)
  field.receiver.key(fixture.key(codes.backspace))
  expect.equal(field.field:value(), '')
  expect.equal(field.receiver.key(fixture.key(codes.left, { 'alt' })), false, 'unsupported chord is unhandled')
end)

test('an error blocks submission until an edit clears it', function()
  local changed: { string }, submitted: { string } = {}, {}
  local field: fixture.Fixture
  field = fixture.new {
    value = 'ok',
    onChange = function(value: string)
      changed[#changed + 1] = value
      expect.equal(field.field:value(), value, 'state precedes callback')
    end,
    onSubmit = function(value: string)
      submitted[#submitted + 1] = value
    end,
  }
  field.field:setValue 'bad'
  field.field:setError 'Use another value.'
  expect.equal(field.field:value(), 'bad')
  expect.equal(field.snapshot().error, 'Use another value.')
  expect.equal(#changed, 0, 'programmatic replacement does not echo onChange')
  field.receiver.key(fixture.key(codes.enter))
  expect.equal(#submitted, 0, 'an error blocks submission')
  field.receiver.key(fixture.key(codes.a, { 'control' }))
  field.receiver.text 'ok'
  expect.equal(changed[1], 'ok')
  expect.equal(field.snapshot().error, nil)
  field.receiver.key(fixture.key(codes.keypadEnter))
  expect.equal(submitted[1], 'ok')
end)

test('primary pointer press chooses the nearest grapheme boundary and captured drag extends selection', function()
  local field = fixture.new { value = 'ab界' }
  local first, second = {}, {}
  field.widget.pointer(fixture.pointer(first, 'press', 25, 'right'))
  expect.equal(field.state.focused, false, 'secondary input does not focus')
  field.widget.pointer(fixture.pointer(first, 'press', 25, 'left'))
  expect.equal(field.state.focused, true)
  local caret, anchor = selection(field)
  expect.equal(caret, 2, 'one codepoint is ten logical units in the deterministic font')
  expect.equal(anchor, 2)
  field.widget.pointer(fixture.pointer(second, 'move', 50, 'left'))
  expect.equal((selection(field)), 2, 'another pointer cannot extend this drag')
  field.widget.pointer(fixture.pointer(first, 'move', 50, 'left'))
  caret, anchor = selection(field)
  expect.equal(caret, #field.field:value() + 1)
  expect.equal(anchor, 2)
  field.widget.pointer(fixture.pointer(first, 'release', 50, 'left'))
  field.widget.pointer(fixture.pointer(first, 'move', 0, 'left'))
  expect.equal((selection(field)), #field.field:value() + 1, 'release ends the drag')
end)

return test
