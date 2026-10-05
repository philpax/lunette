local testing = require '@testing'
local fixture = require './support/protocol'
local expect = testing.expect
local test = testing.suite()

test('invalid cancellation reasons are rejected before any capture changes', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  local count = #f.events
  for _, given in ipairs { {}, { false }, { 3 }, { 'unknown' } } do
    expect.raises(function()
      pointer:cancel(target, given[1])
    end, 'cancellation reason', 'the closed reason boundary')
    expect.equal(#f.events, count, 'rejection delivers no callback')
  end
  f:update(pointer, { target })
  expect.equal(#f:matching('release', pointer, target), 2, 'invalid cancellation preserves both captures')
  for _, reason in ipairs {
    'tracking-loss',
    'pointer-destroyed',
    'surface-dead',
    'surface-withdrawn',
    'provider-replaced',
    'hidden',
    'control-removed',
    'disabled',
    'grab',
  } do
    f:update(pointer, { target }, { buttons = { left = true } })
    pointer:cancel(target, reason)
    local cancelled = f:matching('cancel', pointer, target)
    expect.equal(cancelled[#cancelled].reason, reason, 'each supplied reason is preserved')
    f:update(pointer, { target })
  end
  f:close()
end)

test('nonfinite input is rejected before callbacks and leaves an existing gesture intact', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true } })
  for _, field in ipairs { 'origin', 'direction', 'scrollX', 'scrollY', 'dt', 'pose' } do
    for _, invalid in ipairs { 0 / 0, math.huge, -math.huge } do
      local frame = {
        origin = vector.pack(0, 0, 0),
        direction = vector.pack(0, 0, -1),
        pose = lovr.math.newMat4(),
        buttons = {},
        grip = false,
        dt = 1,
      }
      frame[field] = if field == 'origin' or field == 'direction'
        then vector.pack(invalid, 0, 0)
        elseif field == 'pose' then lovr.math.newMat4():scale(invalid, 1, 1)
        else invalid
      local count = #f.events
      expect.raises(function()
        pointer:update(frame, { target })
      end, 'finite', 'nonfinite ' .. field)
      expect.equal(#f.events, count, 'invalid input delivers no callback')
    end
  end
  f:update(pointer, { target })
  expect.equal(#f:matching('release', pointer, target), 1, 'validation does not sample a false release')
  f:close()
end)

return test
