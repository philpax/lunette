local testing = require '@testing'
local expect = testing.expect
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-contracts/interaction'
local keyboardContract = require '@lunette-contracts/keyboard'
local keyboard = require '@lunette-plugins/keyboard'
local keys = require '@lunette-contracts/keys'
local theme = require '@lunette-contracts/theme'

local test = testing.suite()

local function fixture(options)
  local native = testing.native()
  local f = { native = native, keys = {}, activations = {}, drawn = {}, events = {} }
  local definition = keyboard.define {
    name = 'pointer-adapter-keyboard',
    rows = { { { code = keys.CODES.y }, { code = keys.CODES.n } } },
    layers = { alternate = { { { code = keys.CODES.enter } } } },
    style = { keyUnit = 0.05 },
    onKey = function(board, key, pointer, base)
      f.activations[#f.activations + 1] = pointer
      base(board, key, pointer)
    end,
    drawKey = function(_pass, key, state)
      f.drawn[key.code] = state.hovered
    end,
  }
  f.session = testing.start {
    'theme',
    'drops',
    'focus',
    'interaction',
    { id = 'keyboard', definition = definition },
  }
  local observed = f.session:observe(keyboardContract.capability)
  f.owner, f.service = observed.context, observed.service
  local focus = f.session:observe(focusContract.capability)
  f.focus = focus.service
  f.target = focus.service:register(focus.context, {
    kind = 'local',
    wantsKeyboard = true,
    receiver = {
      key = function(event)
        f.keys[#f.keys + 1] = event.code
        return true
      end,
      text = function()
        return false
      end,
    },
  })
  f.target:focus()
  f.board = f.service:new(f.owner, options)
  local pointers = f.session:observe(interaction.capability)
  function f:pointer()
    return pointers.service:newPointer(pointers.context)
  end
  function f:update(pointer, buttons, x, y)
    pointer:update({
      origin = vector.pack((x or 0.025) - self.board.width / 2, self.board.height / 2 - (y or 0.025), 1),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4(),
      buttons = buttons or {},
      grip = false,
    }, { self.board })
  end
  function f:record()
    local onPointer = self.board.onPointer
    self.board.onPointer = function(board, event)
      self.events[#self.events + 1] = event
      if onPointer then
        onPointer(board, event)
      end
    end
  end
  function f:cancelled(pointer)
    local result = {}
    for _, event in self.events do
      if event.kind == 'cancel' and (not pointer or event.pointer == pointer) then
        result[#result + 1] = event
      end
    end
    return result
  end
  function f:draw()
    table.clear(self.drawn)
    self.board:draw(self.native.events.pass)
    return self.drawn
  end
  function f:close()
    self.session:close()
  end
  return f
end

test('built-in types once on primary press and ignores secondary buttons', function()
  local f = fixture()
  local pointer = f:pointer()
  f:update(pointer, { right = true, middle = true, back = true, forward = true })
  expect.equal(#f.keys, 0, 'secondary presses never type')
  f:update(pointer)
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 1, 'primary press keeps activation on the down edge')
  expect.equal(f.keys[1], keys.CODES.y)
  f:update(pointer, { left = true })
  f:update(pointer)
  expect.equal(#f.keys, 1, 'motion and release do not type again')
  expect.equal(f.activations[1], pointer, 'the hook receives the actual pointer')
  expect.equal(f.focus:focused(), f.target, 'keyboard interaction does not steal local focus')
  f:close()
end)

test('built-in tracking loss never types on cancellation or held reacquisition', function()
  local f = fixture()
  local pointer = f:pointer()
  f:update(pointer, { left = true })
  pointer:withdraw()
  expect.equal(#f.keys, 1, 'tracking loss is not another activation')
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 1, 'a held trigger cannot start another activation')
  f:update(pointer)
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 2, 'an observed release permits a fresh primary press')
  f:close()
end)

test('built-in hide cancels every pointer before visibility notification', function()
  local f
  local notifications = 0
  f = fixture {
    onVisibilityChanged = function(event)
      notifications += 1
      if notifications > 1 then
        return
      end
      expect.falsy(f.board.visible, 'visibility commits before callbacks')
      expect.equal(#f:cancelled(), 3, 'every captured button is cancelled before notification')
      expect.equal(event.reason, 'hide')
    end,
  }
  f:record()
  local first, second = f:pointer(), f:pointer()
  f:update(first, { left = true, right = true })
  f:update(second, { left = true })
  expect.equal(#f.keys, 2, 'two pointers activate independently')
  f.board:setVisible(false)
  expect.equal(notifications, 1, 'one lifecycle notification')
  expect.equal(#f:cancelled(first), 2, 'both buttons of the first pointer cancel')
  expect.equal(#f:cancelled(second), 1, 'the second pointer cancels independently')
  for _, event in f:cancelled() do
    expect.equal(event.reason, 'hidden')
  end
  f.board:setVisible(true)
  f:update(first, { left = true, right = true })
  f:update(second, { left = true })
  expect.equal(#f.keys, 2, 'showing cannot restart held gestures')
  f:update(first)
  f:update(first, { left = true })
  expect.equal(#f.keys, 3, 'a fresh press after showing types')
  f:close()
end)

test('built-in exposes unbounded projection while raycast stays bounded', function()
  local f = fixture()
  expect.truthy(f.board.project, 'capture coordinates have a projection adapter')
  local origin = vector.pack(f.board.width, 0, 1)
  local x, y, distance = f.board:project(origin, vector.pack(0, 0, -1))
  expect.near(x, f.board.width * 1.5, 1e-6, 'projection does not clamp the coordinate')
  expect.near(y, f.board.height / 2, 1e-6)
  expect.near(distance, 1, 1e-6)
  expect.equal(f.board:raycast(origin, vector.pack(0, 0, -1)), nil, 'picking remains bounded')
  f:close()
end)

test('built-in layer changes cancel captures before another control can activate', function()
  local f = fixture()
  f:record()
  local pointer = f:pointer()
  f:update(pointer, { left = true })
  local selected = f.session:observe(theme.capability)
  local selection = selected.service:select(selected.context, { colors = { control = { 0.6, 0.5, 0.4, 1 } } })
  expect.equal(#f:cancelled(), 0, 'palette changes preserve this board capture')
  f.board:setLayer 'alternate'
  expect.equal(#f:cancelled(), 1, 'an incompatible control change cancels immediately')
  expect.equal(f:cancelled()[1].reason, 'control-removed')
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 1, 'a held gesture cannot activate a changed control')
  f:update(pointer)
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 2, 'a fresh press activates the new control')
  selection:dispose()
  f:close()
end)

test('built-in hover leave and cancellation clear only the actual pointer', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  f:update(first, { left = true })
  f:update(second, { left = true }, 0.075)
  expect.truthy(f:draw()[keys.CODES.y], 'the first pointer hovers y')
  expect.truthy(f.drawn[keys.CODES.n], 'the second pointer hovers n')
  first:cancel(f.board, 'disabled')
  expect.falsy(f:draw()[keys.CODES.y], 'cancellation clears the first hover')
  expect.truthy(f.drawn[keys.CODES.n], 'cancellation preserves the second hover')
  f:update(second, { left = true }, f.board.width * 2)
  expect.falsy(f:draw()[keys.CODES.n], 'outside captured motion cannot leave stale hover')
  expect.equal(#f.keys, 2, 'neither cancellation nor outside movement types')
  f:close()
end)

return test
