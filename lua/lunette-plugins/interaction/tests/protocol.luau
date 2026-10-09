local testing = require '@testing'
local vocabulary = require '@lunette-contracts/vocabulary'
local fixture = require './support/protocol'
local expect = testing.expect
local test = testing.suite()

test('surface capture preserves every button and real pointer identity', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local target = f:surface 'plate'
  local held = {}
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    held[button] = true
  end
  f:update(first, { target }, { buttons = held })
  f:update(second, { target }, { buttons = { left = true } })
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    local pressed = f:matching('press', first, target, button)
    expect.equal(#pressed, 1, 'one press for the actual button')
    expect.truthy(pressed[1].captured and pressed[1].inside, 'press starts inside its capture')
  end
  expect.equal(#f:matching('press', second, target, 'left'), 1, 'the second pointer has its own capture')
  f:update(first, { target })
  expect.equal(#f:matching('release', first, target), #vocabulary.POINTER_BUTTONS, 'each button releases once')
  expect.equal(#f:matching('release', second, target), 0, 'the first pointer cannot release the second')
  f:update(second, { target })
  expect.equal(#f:matching('release', second, target, 'left'), 1, 'the second releases its own button')
  f:close()
end)

test('captured motion projects outside bounds and release reaches the original surface', function()
  local f = fixture()
  local pointer = f:pointer()
  local original, replacement = f:surface 'original', f:surface 'replacement'
  function replacement:raycast(origin)
    if origin.x > 0.5 then
      return 0.25, 0.5, 0.5
    end
    return nil, nil, nil
  end
  f:update(pointer, { original, replacement }, { buttons = { left = true } })
  f:update(pointer, { original, replacement }, { x = 2, buttons = { left = true } })
  local moved = f:matching('move', pointer, original, 'left')
  expect.truthy(#moved > 0, 'the captured surface receives motion')
  expect.near(moved[#moved].x, 2.5, 1e-6, 'unbounded projection is not clamped')
  expect.falsy(moved[#moved].inside, 'the ray is outside the original surface')
  expect.equal(#f:matching('cancel', pointer, original), 0, 'hover leave does not cancel capture')
  f:update(pointer, { original, replacement }, { x = 2 })
  local released = f:matching('release', pointer, original, 'left')
  expect.equal(#released, 1, 'release reaches the surface pressed earlier')
  expect.falsy(released[1].inside, 'an outside release cannot activate an inside-only control')
  expect.equal(#f:matching('release', pointer, replacement), 0, 'hover does not redirect release')
  f:close()
end)

test('dead and withdrawn surfaces cancel while a held trigger cannot reacquire a replacement', function()
  for _, cause in ipairs { 'surface-dead', 'surface-withdrawn' } do
    local f = fixture()
    local pointer, target = f:pointer(), f:surface 'plate'
    f:update(pointer, { target }, { buttons = { left = true } })
    local replacement = f:surface 'replacement'
    if cause == 'surface-dead' then
      target.dead = true
    end
    f:update(pointer, { replacement }, { buttons = { left = true } })
    local cancelled = f:matching('cancel', pointer, target, 'left')
    expect.equal(#cancelled, 1, 'the old capture cancels exactly once')
    expect.equal(cancelled[1].reason, cause, 'the surface loss reason')
    expect.equal(#f:matching('press', pointer, replacement), 0, 'held input does not acquire a replacement')
    f:update(pointer, { replacement })
    f:update(pointer, { replacement }, { buttons = { left = true } })
    expect.equal(#f:matching('press', pointer, replacement), 1, 'a new edge acquires the replacement')
    f:close()
  end
end)

test('explicit surface cancellation preserves another pointer and requires a fresh press edge', function()
  local f = fixture()
  local first, second, target = f:pointer(), f:pointer(), f:surface 'plate'
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { left = true } })
  first:cancel(target, 'disabled')
  expect.equal(#f:matching('cancel', first, target), 1, 'the requested capture cancels')
  expect.equal(#f:matching('cancel', second, target), 0, 'another pointer is independent')
  f:update(first, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', first, target), 1, 'the cancelled held button stays ineligible')
  f:update(second, { target })
  expect.equal(#f:matching('release', second, target), 1, 'the unaffected pointer releases normally')
  f:update(first, { target })
  f:update(first, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', first, target), 2, 'an observed release permits another gesture')
  f:close()
end)

test('UI scroll applies pointer tuning once and does not invoke a native sink', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { scrollX = 0.1, scrollY = 1, dt = 0.25 })
  local scrolled = f:matching('scroll', pointer, target)
  expect.equal(#scrolled, 1, 'one scroll event')
  expect.equal(scrolled[1].dx, 0, 'dead-zone x is zero')
  expect.near(scrolled[1].dy, -pointer.tuning.scrollScale * 0.25, 1e-6, 'scale, dt, and vertical inversion apply once')
  f:close()
end)

test('native sink motion buttons and scaled scroll never duplicate surface protocol callbacks', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'native'
  local moved, down, up, scrolled = 0, 0, 0, 0
  local sink = {
    dead = false,
    domain = 'host',
    monitor = { id = 'native-pointer-compatibility' },
    focus = function()
      return true
    end,
    pointer = function()
      moved += 1
    end,
    button = function(_self, button, pressed)
      expect.equal(button, 'right', 'the actual native button')
      if pressed then
        down += 1
      else
        up += 1
      end
    end,
    scroll = function(_self, dx, dy)
      scrolled += 1
      expect.equal(dx, 0, 'the scaled native horizontal delta')
      expect.near(dy, -pointer.tuning.scrollScale, 1e-6, 'the native vertical delta scales once')
    end,
    leave = function() end,
  }
  function target:sink()
    return sink
  end
  f:update(pointer, { target }, { buttons = { right = true }, scrollY = 1 })
  f:update(pointer, { target })
  expect.equal(down, 1, 'one native press')
  expect.equal(up, 1, 'one native release')
  expect.equal(scrolled, 1, 'one native scroll')
  expect.truthy(moved > 0, 'native motion remains available')
  expect.equal(#f.events, 0, 'a native sink receives no duplicate protocol events')
  f:close()
end)

return test
