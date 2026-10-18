local testing = require '@testing'
local poke = require '../private/poke'
local expect = testing.expect
local test = testing.suite()

local PANEL = {}

-- Steps the hand through fingertip depths in front of one panel, collecting the event kinds. A false depth is a
-- frame without tracking.
local function run(hand: poke.Hand, depths: { number | false }, dt: number?): { string }
  local kinds: { string } = {}
  for _, depth in depths do
    local candidates: { poke.Candidate }? = if depth == false
      then nil
      else { { panel = PANEL, x = 0.1, y = 0.1, depth = depth :: number } }
    for _, event in poke.step(hand, candidates, dt or 0.011) do
      if event.kind ~= 'move' then
        table.insert(kinds, event.kind)
      end
    end
  end
  return kinds
end

test('a fingertip from the front presses past the activation depth and releases on recoil', function()
  local hand = poke.new()
  local kinds = run(hand, { 0.1, 0.04, 0.02, 0.005, -0.001, -0.003, -0.005, -0.004, -0.0015 })
  expect.equal(table.concat(kinds, ' '), 'enter press release')
end)

test('jitter smaller than the release gap neither releases nor presses again', function()
  local hand = poke.new()
  local kinds = run(hand, { 0.1, 0.02, -0.003, -0.005, -0.004, -0.006, -0.0045, -0.006 })
  expect.equal(table.concat(kinds, ' '), 'enter press')
end)

test('a fingertip that appears inside the zone cannot press until it retreats', function()
  local hand = poke.new()
  expect.equal(table.concat(run(hand, { 0.01, -0.004, -0.006 }), ' '), 'enter')
  expect.equal(table.concat(run(hand, { 0.04, 0.01, -0.004 }), ' '), 'press')
end)

test('moving back towards the surface by the re-arm gap arms another press', function()
  local hand = poke.new()
  run(hand, { 0.1, 0.02, -0.004, -0.008 })
  local kinds = run(hand, { -0.004, -0.002, -0.0045, -0.006 })
  expect.equal(table.concat(kinds, ' '), 'release press')
end)

test('a brief tracking loss keeps the press, and a long one cancels it', function()
  local hand = poke.new()
  run(hand, { 0.1, 0.02, -0.004 })
  expect.equal(#run(hand, { false, false }, 0.05), 0, 'within the grace period nothing changes')
  expect.truthy(hand.pressed)
  expect.equal(table.concat(run(hand, { false, false }, 0.1), ' '), 'cancel')
  expect.equal(
    table.concat(run(hand, { 0.01, -0.004 }), ' '),
    'enter',
    'a returning fingertip must enter from the front'
  )
end)

test('leaving past the exit distance ends the hover, and cancels a press', function()
  local hand = poke.new()
  expect.equal(table.concat(run(hand, { 0.1, 0.02, 0.06 }), ' '), 'enter leave')
  expect.equal(table.concat(run(hand, { 0.1, 0.02, -0.004, 0.06 }), ' '), 'enter press release leave')
  local sliding = poke.new()
  run(sliding, { 0.1, 0.02, -0.004 })
  local kinds: { string } = {}
  for _, event in poke.step(sliding, {}, 0.011) do
    table.insert(kinds, event.kind)
  end
  expect.equal(table.concat(kinds, ' '), 'cancel', 'sliding off the panel while pressed cancels')
end)

return test
