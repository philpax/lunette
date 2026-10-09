local testing = require '@testing'
local lunette = require '@lunette'
local keys = require '@lunette-contracts/keys'
local edit = require '../text-edit'
local fixture = require './support/text-field'
local expect = testing.expect
local test = testing.suite()
local codes = keys.CODES

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

local function isBoundary(value, position)
  return table.find(lunette.textBoundaries(value), position) ~= nil
end

local function invariant(state)
  expect.truthy(utf8.len(state.value) ~= nil, 'valid UTF-8')
  expect.truthy(isBoundary(state.value, state.caret), 'caret is an extended grapheme boundary')
  expect.truthy(isBoundary(state.value, state.anchor), 'anchor is an extended grapheme boundary')
end

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
    invariant(backward)
    invariant(forward)
  end
end)

test('insertion and selection replacement round-trip at every native boundary', function()
  local values = { '', 'a', table.concat(clusters, '|') }
  for first = 1, #clusters do
    for second = 1, #clusters do
      values[#values + 1] = clusters[first] .. '|' .. clusters[second]
    end
  end
  for _, value in values do
    for _, boundary in lunette.textBoundaries(value) do
      local original = edit.select(edit.new(value), boundary)
      for _, inserted in clusters do
        local changed = edit.insert(original, inserted .. '|')
        invariant(changed)
        expect.equal(changed.value, value:sub(1, boundary - 1) .. inserted .. '|' .. value:sub(boundary))
        local restored = edit.insert(edit.select(changed, boundary + #inserted + 1, boundary), '')
        expect.equal(restored.value, value, 'selected insertion round-trips')
        invariant(restored)
      end
    end
  end
end)

test('resegments inserted combining and ZWJ text without leaving an interior caret', function()
  local state = edit.select(edit.new 'e', 2)
  state = edit.insert(state, utf8.char(0x301))
  expect.equal(state.value, 'e' .. utf8.char(0x301))
  invariant(state)
  state = edit.select(edit.new(utf8.char(0x1f469, 0x1f4bb)), 5)
  state = edit.insert(state, utf8.char(0x200d))
  invariant(state)
  expect.equal(state.caret, #state.value + 1, 'caret snaps after the joined cluster')
  expect.equal(edit.erase(state, 'backward').value, '')
end)

test('repeated grapheme deletion terminates at empty and preserves every intermediate invariant', function()
  for _, value in { '', 'a', table.concat(clusters, '|') } do
    for _, direction in { 'backward', 'forward' } do
      local state = edit.new(value)
      if direction == 'forward' then
        state = edit.select(state, 1)
      end
      local limit = #lunette.textBoundaries(value)
      for _ = 1, limit do
        local before = state.value
        state = edit.erase(state, direction)
        invariant(state)
        if before ~= '' then
          expect.truthy(#state.value < #before, 'a whole grapheme is removed')
        end
      end
      expect.equal(state.value, '')
      expect.equal(state.caret, 1)
      expect.equal(state.anchor, 1)
    end
  end
end)

test('movement is bounded, selection-aware, and reversible across all clusters', function()
  for _, value in { '', 'a', table.concat(clusters, '|') } do
    local state = edit.select(edit.new(value), 1)
    local boundaries = lunette.textBoundaries(value)
    for index = 2, #boundaries do
      state = edit.move(state, 'right', false)
      expect.equal(state.caret, boundaries[index])
      invariant(state)
    end
    expect.equal(edit.move(state, 'right', false).caret, #value + 1)
    for index = #boundaries - 1, 1, -1 do
      state = edit.move(state, 'left', false)
      expect.equal(state.caret, boundaries[index])
    end
    expect.equal(edit.move(state, 'left', false).caret, 1)
    state = edit.move(state, 'end', true)
    expect.equal(state.anchor, 1)
    expect.equal(state.caret, #value + 1)
    expect.equal(edit.move(state, 'left', false).caret, 1, 'left collapses to selection start')
    expect.equal(edit.move(state, 'right', false).caret, #value + 1, 'right collapses to selection end')
  end
end)

test('rejects malformed UTF-8 and unsupported single-line content atomically', function()
  local field = fixture.new { value = 'draft' }
  field.field:setSelection(3, 2)
  for _, invalid in
    {
      string.char(255),
      string.char(0xc0, 0xaf),
      string.char(0xed, 0xa0, 0x80),
      '\n',
      '\r',
      '\t',
      '\0',
      utf8.char(0x7f),
      utf8.char(0x85),
      utf8.char(0x2028),
      utf8.char(0x2029),
    }
  do
    expect.raises(function()
      field.receiver.text(invalid)
    end, 'text field:')
    expect.equal(field.field:value(), 'draft')
    local caret, anchor = field.field:selection()
    expect.equal(caret, 3)
    expect.equal(anchor, 2)
    expect.raises(function()
      field.field:setValue(invalid)
    end, 'text field:')
  end
  expect.equal(field.state.changes, 1, 'rejected edits do not publish changes')
end)

test('rejects interior, out-of-range, and noninteger public selection offsets', function()
  local field = fixture.new { value = clusters[4] .. 'x' }
  for _, position in { 0, 2, 3, 1.5, math.huge, 0 / 0, #field.field:value() + 2 } do
    expect.raises(function()
      field.field:setSelection(position)
    end, 'boundary')
  end
  field.field:setSelection(1, #field.field:value() + 1)
  local caret, anchor = field.field:selection()
  expect.equal(caret, 1)
  expect.equal(anchor, #field.field:value() + 1)
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
  local caret, anchor = field.field:selection()
  expect.equal(caret, #field.field:value() + 1)
  expect.equal(anchor, 1)
  field.receiver.key(fixture.key(codes.backspace))
  expect.equal(field.field:value(), '')
  expect.equal(field.receiver.key(fixture.key(codes.left, { 'alt' })), false, 'unsupported chord is unhandled')
end)

test('retains invalid drafts and prevents submission until validation passes', function()
  local changed, submitted = {}, {}
  local field
  field = fixture.new {
    value = 'ok',
    validate = function(value)
      return if value == 'bad' then 'Use another value.' else nil
    end,
    onChange = function(value)
      changed[#changed + 1] = value
      expect.equal(field.field:value(), value, 'state precedes callback')
    end,
    onSubmit = function(value)
      submitted[#submitted + 1] = value
    end,
  }
  field.field:setValue 'bad'
  expect.equal(field.field:value(), 'bad')
  expect.equal(field.snapshot().error, 'Use another value.')
  expect.equal(#changed, 0, 'programmatic replacement does not echo onChange')
  field.receiver.key(fixture.key(codes.enter))
  expect.equal(#submitted, 0)
  field.receiver.key(fixture.key(codes.a, { 'control' }))
  field.receiver.text 'ok'
  expect.equal(changed[1], 'ok')
  expect.equal(field.snapshot().error, nil)
  field.receiver.key(fixture.key(codes.keypadEnter))
  expect.equal(submitted[1], 'ok')
end)

test('reports validator and change callback failures through the host without losing the draft', function()
  local field = fixture.new {
    onChange = function()
      error 'change failed'
    end,
  }
  field.receiver.text 'retained'
  expect.equal(field.field:value(), 'retained')
  expect.equal(field.state.reports[1].name, 'onChange')
  field = fixture.new {
    validate = function(value)
      if value ~= '' then
        error 'validator failed'
      end
    end,
  }
  field.receiver.text 'retained'
  expect.equal(field.field:value(), 'retained')
  expect.truthy(field.snapshot().error, 'validator failure is visible')
  expect.equal(field.state.reports[1].name, 'validate')
end)

test('empty text commits preserve selections and published snapshots remain detached', function()
  local field = fixture.new { value = 'draft' }
  field.field:setSelection(3, 1)
  local snapshot = field.snapshot()
  expect.equal(field.receiver.text '', true)
  local caret, anchor = field.field:selection()
  expect.equal(caret, 3)
  expect.equal(anchor, 1)
  field.receiver.text 'new'
  expect.equal(snapshot.value, 'draft')
  expect.equal(snapshot.caret, 3)
  expect.equal(snapshot.anchor, 1)
  expect.equal(field.field:value(), 'newaft')
end)

test('cancel retains the draft, blurs first, and invokes the protected cancel callback', function()
  local field, cancelled = nil, nil
  field = fixture.new {
    value = 'draft',
    onCancel = function(value)
      cancelled = value
      expect.equal(field.snapshot().focused, false, 'blur precedes callback')
    end,
  }
  expect.equal(field.field:focus(), true)
  field.receiver.key(fixture.key(codes.escape))
  expect.equal(cancelled, 'draft')
  expect.equal(field.field:value(), 'draft')
  field.field:setError 'External error.'
  expect.equal(field.snapshot().error, 'External error.')
  field.field:setError(nil)
  expect.equal(field.snapshot().error, nil)
end)

test('primary pointer press chooses the nearest grapheme boundary and captured drag extends selection', function()
  local field = fixture.new { value = 'ab界' }
  local first, second = {}, {}
  field.widget.pointer(fixture.pointer(first, 'press', 25, 'right', true))
  expect.equal(field.state.focused, false, 'secondary input does not focus')
  field.widget.pointer(fixture.pointer(first, 'press', 25, 'left', true))
  expect.equal(field.state.focused, true)
  local caret, anchor = field.field:selection()
  expect.equal(caret, 2, 'one codepoint is ten logical units in the deterministic font')
  expect.equal(anchor, 2)
  field.widget.pointer(fixture.pointer(second, 'move', 50, 'left', true))
  expect.equal(field.field:selection(), 2, 'another pointer cannot extend this drag')
  field.widget.pointer(fixture.pointer(first, 'move', 50, 'left', true))
  caret, anchor = field.field:selection()
  expect.equal(caret, #field.field:value() + 1)
  expect.equal(anchor, 2)
  field.widget.pointer(fixture.pointer(first, 'release', 0, 'left', true))
  caret, anchor = field.field:selection()
  expect.equal(caret, 1, 'captured release outside clamps to the first boundary')
  expect.equal(anchor, 2)
  field.widget.pointer(fixture.pointer(first, 'move', 50, 'left', true))
  expect.equal(field.field:selection(), 1, 'release ends the drag')
end)

test('focus loss and pointer cancellation end drags without erasing text or selection', function()
  local field = fixture.new { value = 'abc' }
  local pointer = {}
  field.widget.pointer(fixture.pointer(pointer, 'press', 14, 'left', true))
  field.widget.pointer(fixture.pointer(pointer, 'move', 34, 'left', true))
  field.widget.onFocus(false)
  field.widget.pointer(fixture.pointer(pointer, 'move', 44, 'left', true))
  expect.equal(field.field:selection(), 3)
  field.widget.pointer(fixture.pointer(pointer, 'press', 14, 'left', true))
  local event = fixture.pointer(pointer, 'cancel', nil, 'left', true)
  event.reason = 'tracking-loss'
  field.widget.pointer(event)
  field.widget.pointer(fixture.pointer(pointer, 'move', 44, 'left', true))
  expect.equal(field.field:selection(), 1)
  expect.equal(field.field:value(), 'abc')
  field.state.live = false
  field.widget.onFocus(false)
  expect.equal(field.snapshot().focused, false, 'disable or disposal still clears visual focus')
end)

return test
