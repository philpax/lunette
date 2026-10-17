local testing = require '@testing'
local vocabulary = require '@lunette-contracts/vocabulary'
local fixture = require './support/protocol'
local expect = testing.expect
local test = testing.suite()

type Sink = {
  dead: boolean,
  domain: 'host',
  monitor: { read id: string },
  pointer: () -> (),
  button: (Sink, string, boolean) -> (),
  scroll: (Sink, number, number) -> (),
  leave: () -> (),
}

test('each pointer captures its own buttons on a surface', function()
  local f = fixture()
  local first, second = f:pointer(), f:pointer()
  local target = f:surface 'plate'
  local held: { [string]: boolean } = {}
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    held[button] = true
  end
  f:update(first, { target }, { buttons = held })
  f:update(second, { target }, { buttons = { left = true } })
  for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
    expect.equal(#f:matching('press', first, target, button), 1, 'one press for each button')
  end
  f:update(first, { target })
  expect.equal(#f:matching('release', first, target), #vocabulary.POINTER_BUTTONS, 'each button releases once')
  expect.equal(#f:matching('release', second, target), 0, 'the first pointer cannot release the second')
  f:close()
end)

test('captured motion projects outside bounds and release reaches the original surface', function()
  local f = fixture()
  local pointer = f:pointer()
  local original, replacement = f:surface 'original', f:surface 'replacement'
  function replacement:raycast(origin: vector): (number?, number?, number?)
    if origin.x > 0.5 then
      return 0.25, 0.5, 0.5
    end
    return nil, nil, nil
  end
  f:update(pointer, { original, replacement }, { buttons = { left = true } })
  f:update(pointer, { original, replacement }, { x = 2, buttons = { left = true } })
  local moved = f:matching('move', pointer, original, 'left')
  expect.near(moved[#moved].x, 2.5, 1e-6, 'unbounded projection is not clamped')
  expect.falsy(moved[#moved].inside, 'the ray is outside the original surface')
  f:update(pointer, { original, replacement }, { x = 2 })
  local released = f:matching('release', pointer, original, 'left')
  expect.equal(#released, 1, 'release reaches the surface pressed earlier')
  expect.falsy(released[1].inside, 'an outside release cannot activate an inside-only control')
  expect.equal(#f:matching('release', pointer, replacement), 0, 'hover does not redirect release')
  f:close()
end)

test('a dead surface cancels its capture and a held trigger cannot press a replacement', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true } })
  local replacement = f:surface 'replacement'
  target.dead = true
  f:update(pointer, { replacement }, { buttons = { left = true } })
  local cancelled = f:matching('cancel', pointer, target, 'left')
  expect.equal(#cancelled, 1, 'the old capture cancels once')
  expect.equal(cancelled[1].reason, 'surface-dead', 'the surface loss reason')
  expect.equal(#f:matching('press', pointer, replacement), 0, 'held input does not acquire a replacement')
  f:update(pointer, { replacement })
  f:update(pointer, { replacement }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, replacement), 1, 'a new edge acquires the replacement')
  f:close()
end)

test('explicit cancellation affects one pointer and requires a fresh press', function()
  local f = fixture()
  local first, second, target = f:pointer(), f:pointer(), f:surface 'plate'
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { left = true } })
  first:cancel(target, 'disabled')
  expect.equal(#f:matching('cancel', first, target), 1, 'the requested capture cancels')
  expect.equal(#f:matching('cancel', second, target), 0, 'another pointer is independent')
  f:update(first, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', first, target), 1, 'the cancelled held button stays ineligible')
  f:update(first, { target })
  f:update(first, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', first, target), 2, 'a release permits another gesture')
  f:close()
end)

test('scroll is scaled once for surfaces and native sinks alike', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { scrollX = 0.1, scrollY = 1, dt = 0.25 })
  local scrolled = f:matching('scroll', pointer, target)
  expect.equal(#scrolled, 1, 'one scroll event')
  expect.equal(scrolled[1].dx, 0, 'dead-zone x is zero')
  expect.near(scrolled[1].dy, -pointer.tuning.scrollScale * 0.25, 1e-6, 'scale, dt, and vertical inversion')
  f:close()
end)

test('a native sink receives buttons and scroll instead of surface events', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'native'
  local down, up, scrolled = 0, 0, 0
  local sink: Sink = {
    dead = false,
    domain = 'host',
    monitor = { id = 'native-pointer' },
    pointer = function() end,
    button = function(_self: Sink, button: string, pressed: boolean)
      expect.equal(button, 'right', 'the actual native button')
      if pressed then
        down += 1
      else
        up += 1
      end
    end,
    scroll = function(_self: Sink, _dx: number, dy: number)
      scrolled += 1
      expect.near(dy, -pointer.tuning.scrollScale, 1e-6, 'the native vertical delta scales once')
    end,
    leave = function() end,
  }
  function target:sink(): Sink
    return sink
  end
  f:update(pointer, { target }, { buttons = { right = true }, scrollY = 1 })
  f:update(pointer, { target })
  expect.equal(down + up + scrolled, 3, 'one press, one release, and one scroll')
  expect.equal(#f.events, 0, 'no duplicate surface events')
  f:close()
end)

test('nonfinite input is rejected without disturbing a held gesture', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true } })
  local count = #f.events
  expect.raises(function()
    pointer:update({
      origin = vector.pack(0 / 0, 0, 0),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4(),
      buttons = {},
      grip = false,
      dt = 1,
    }, { target })
  end, 'finite', 'a nan origin')
  expect.equal(#f.events, count, 'invalid input delivers no callback')
  f:update(pointer, { target })
  expect.equal(#f:matching('release', pointer, target), 1, 'the gesture releases normally')
  f:close()
end)

test('trigger grab queries receive the current finite hit and cannot continue after teardown', function()
  for _, destroyPointer in { false, true } do
    local f = fixture()
    local pointer = f:pointer()
    local target = f:surface 'query'
    target.pose = lovr.math.newMat4()
    target.setPose = function() end
    local queries = 0
    target.triggerGrabs = function(_self: any, x: number, y: number): boolean
      queries += 1
      expect.near(x, 0.7, 1e-6, 'the current hit x reaches the query')
      expect.near(y, 0.5, 1e-6, 'the current hit y reaches the query')
      if destroyPointer then
        pointer:destroy()
      else
        target.dead = true
      end
      return true
    end
    f:update(pointer, { target }, { x = 0.2, buttons = { left = true } })
    expect.equal(queries, 1, 'one query on the primary edge')
    expect.equal(pointer.grabbed, nil, 'a dead query participant cannot acquire a grab')
    expect.equal(#f:matching 'press', 0, 'teardown cannot fall through to press delivery')
    f:close()
  end
end)

test('trigger grab query results are validated', function()
  local f = fixture()
  local pointer = f:pointer()
  local target = f:surface 'invalid-query'
  target.triggerGrabs = function(): any
    return 'yes'
  end
  local ok, failure = pcall(function()
    f:update(pointer, { target }, { buttons = { left = true } })
  end)
  expect.falsy(ok, 'a non-boolean query result is rejected')
  expect.truthy(tostring(failure):find('triggerGrabs answers a boolean', 1, true), 'the error identifies the query')
  f:close()
end)

return test
