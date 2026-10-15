local testing = require '@testing'
local expect = testing.expect
local focusContract = require '@lunette-contracts/focus'
local interaction = require '@lunette-contracts/interaction'
local keyboardContract = require '@lunette-contracts/keyboard'
local keyboard = require '../'
local keys = require '@lunette-contracts/keys'

local test = testing.suite()

type Fixture = {
  native: testing.Native,
  keys: { number },
  activations: { interaction.Pointer },
  session: testing.Session?,
  owner: focusContract.Owner?,
  service: keyboardContract.Service?,
  focus: focusContract.Service?,
  target: focusContract.TargetHandle?,
  board: keyboardContract.Keyboard?,
  pointer: (Fixture) -> interaction.Pointer,
  update: (Fixture, interaction.Pointer, { [string]: boolean }?, number?, number?) -> (),
  close: (Fixture) -> (),
}

local function fixture(): Fixture
  local native = testing.native()
  local f: Fixture = { native = native, keys = {}, activations = {} }
  local definition = keyboard.define {
    name = 'pointer-adapter-keyboard',
    rows = { { { code = keys.CODES.y }, { code = keys.CODES.n } } },
    style = { keyUnit = 0.05 },
    onKey = function(board: keyboard.Board, key: keyboard.RenderedKey, pointer: keyboard.Pointer, base: keyboard.Press)
      f.activations[#f.activations + 1] = pointer
      base(board, key, pointer)
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
      key = function(event: focusContract.KeyEvent): boolean
        f.keys[#f.keys + 1] = event.code
        return true
      end,
      text = function(): boolean
        return false
      end,
    },
  })
  f.target:focus()
  f.board = f.service:new(f.owner)
  local pointers = f.session:observe(interaction.capability)
  function f:pointer(): interaction.Pointer
    return pointers.service:newPointer(pointers.context)
  end
  function f:update(pointer: interaction.Pointer, buttons: { [string]: boolean }?, x: number?, y: number?)
    pointer:update({
      origin = vector.pack((x or 0.025) - self.board.width / 2, self.board.height / 2 - (y or 0.025), 1),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4(),
      buttons = buttons or {},
      grip = false,
    }, { self.board })
  end
  function f:close()
    self.session:close()
  end
  return f
end

test('a primary press types once, secondary buttons never type, and tracking loss never types', function()
  local f = fixture()
  local pointer = f:pointer()
  f:update(pointer, { right = true, middle = true })
  expect.equal(#f.keys, 0, 'secondary presses never type')
  f:update(pointer)
  f:update(pointer, { left = true })
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 1, 'a held press types once')
  expect.equal(f.keys[1], keys.CODES.y)
  expect.equal(f.activations[1], pointer, 'the hook receives the actual pointer')
  expect.equal(f.focus:focused(), f.target, 'keyboard interaction does not steal focus')
  pointer:withdraw()
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 1, 'neither tracking loss nor a held reacquisition types')
  f:update(pointer)
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 2, 'an observed release permits a fresh press')
  f:close()
end)

test('hiding the keyboard cancels its captured pointers, and showing it does not restart them', function()
  local f = fixture()
  local cancelled: { interaction.CancelReason } = {}
  local onPointer = f.board.onPointer
  f.board.onPointer = function(board: keyboardContract.Surface, event: interaction.PointerEvent)
    if event.kind == 'cancel' then
      cancelled[#cancelled + 1] = event.reason
    end
    onPointer(board, event)
  end
  local pointer = f:pointer()
  f:update(pointer, { left = true })
  f.board:setVisible(false)
  expect.equal(table.concat(cancelled, ','), 'hidden', 'the cancellation')
  f.board:setVisible(true)
  f:update(pointer, { left = true })
  expect.equal(#f.keys, 1, 'showing does not restart a held press')
  f:close()
end)

return test
