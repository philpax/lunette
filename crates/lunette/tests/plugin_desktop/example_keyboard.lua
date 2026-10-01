-- The keyboard example in examples/keyboard: its main.lua starts the shipped
-- desktop with its patches, and its split keyboard, run in that composition,
-- lays out its halves, switches to its numpad, clicks the pressing hand, and
-- flashes the pressed key. The rounded variant draws rounded faces, and the
-- keyboard written from nothing serves the wrist button in the built-in's
-- place.
require 'main'
lovr.load()
events.draw = {}
lovr.update(0.016)
assert(lovr.draw(events.pass) == false)
local split = package.loaded['./split']
assert(split and split.name == 'split-keyboard', 'main.lua patches in the split keyboard')
assert(lovr.quit() == false)

local plugin = require '@lunette-plugin'
local keyboardContract = require '@lunette-contracts/keyboard'
local interactionContract = require '@lunette-contracts/interaction'

local function started(definition)
  local desktop = require 'fixture/graph' {
    patches = {
      { id = 'keyboard', definition = definition },
      { id = 'desktop/keyboard', config = { hand = 'right' } },
    },
  }
  for id, instance in pairs(desktop.instances) do
    assert(instance:state() == 'active', id .. ': ' .. tostring(instance:diagnostic()))
  end
  local wrist, right
  for _, candidate in ipairs(desktop.surfaces:all()) do
    if candidate.grabbable == false and candidate.width == 0.115 then
      wrist = candidate
    end
  end
  local pointers
  desktop.runtime
    :use(
      plugin.define {
        name = 'example-probe',
        requires = { interaction = interactionContract.capability, keyboard = keyboardContract.capability },
        init = function(ctx)
          pointers = ctx:require(interactionContract.capability)
        end,
      },
      {}
    )
    :enable()
  for _, pointer in ipairs(pointers:pointers()) do
    if pointer.seat and pointer.seat.name == 'laser.right' then
      right = pointer
    end
  end
  wrist:onPress(nil, nil, right)
  local board
  for _, candidate in ipairs(desktop.surfaces:all()) do
    if candidate.pressKey then
      board = candidate
    end
  end
  assert(board and board.visible, 'the wrist button shows the keyboard')
  return board, right
end

local board, right = started(split)
local unit = 0.03
-- Eleven keys wide on the number row: ten keys, a wider backspace, and the split.
assert(math.abs(board.width - 13 * unit) < 1e-9, tostring(board.width / unit))
local placed = board:keys()
local six, five
for _, key in ipairs(placed) do
  if key.code == 7 then
    six = key
  elseif key.code == 6 then
    five = key
  end
end
assert(math.abs(six.x - (five.x + five.width + 1.5 * unit)) < 1e-9, 'the halves are split')

local function find(predicate)
  for _, key in ipairs(board:keys()) do
    if predicate(key) then
      return key
    end
  end
  error 'no such key'
end
local function press(key)
  board:onPress(key.x + key.width / 2, key.y + key.height / 2, right)
end

local haptics = events.haptics
press(find(function(key)
  return key.action ~= nil and key.action.kind == 'layer'
end))
assert(events.haptics == haptics + 1 and events.haptic.device == 'hand/right', 'a key press clicks the pressing hand')
assert(board.layer == 'numpad')
local plus = find(function(key)
  return key.legend == '+'
end)
assert(math.abs(plus.height - 2 * unit) < 1e-9, 'the numpad plus is two rows tall')

-- The pressed key flashes until the flash runs out.
events.time = 10
press(plus)
events.draw = {}
board:draw(events.pass)
local flashed = false
for _, call in ipairs(events.draw) do
  flashed = flashed or (call[1] == 'setColor' and call[2] == 1 and call[3] == 0.8)
end
assert(flashed, 'the pressed key is drawn lit')
events.time = 11
events.draw = {}
board:draw(events.pass)
for _, call in ipairs(events.draw) do
  assert(not (call[1] == 'setColor' and call[2] == 1 and call[3] == 0.8), 'the flash ends')
end
assert(lovr.quit() == false)

-- The rounded variant draws its faces with roundrect and keeps the default
-- legends.
local rounded = require './rounded'
local roundedBoard = started(rounded)
events.draw = {}
roundedBoard:draw(events.pass)
local faces, legends = 0, 0
for _, call in ipairs(events.draw) do
  if call[1] == 'roundrect' then
    faces += 1
  elseif call[1] == 'text' then
    legends += 1
  end
end
assert(faces > 0 and faces == legends, faces .. ' faces, ' .. legends .. ' legends')
assert(lovr.quit() == false)

-- The keyboard written from nothing takes the built-in's place.
local tinyBoard, tinyPointer = started(require './tiny')
assert(math.abs(tinyBoard.width - 0.15) < 1e-9)
haptics = events.haptics
tinyBoard:onPress(0.025, 0.025, tinyPointer)
assert(events.haptics == haptics + 1, 'a tiny key clicks the pressing hand')
events.draw = {}
tinyBoard:draw(events.pass)
local planes, labels = 0, 0
for _, call in ipairs(events.draw) do
  if call[1] == 'plane' then
    planes += 1
  elseif call[1] == 'text' then
    labels += 1
  end
end
assert(planes == 3 and labels == 3)
assert(lovr.quit() == false)
