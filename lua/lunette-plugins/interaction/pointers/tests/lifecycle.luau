local testing = require '@testing'
local fixture = require './support/protocol'
local expect = testing.expect
local test = testing.suite()

test('tracking loss cancels captures and ignores held buttons until all are released', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  pointer:withdraw()
  expect.equal(#f:matching('release', pointer, target), 0, 'tracking loss is not release')
  local cancelled = f:matching('cancel', pointer, target)
  expect.equal(#cancelled, 2, 'both active buttons cancel')
  expect.equal(cancelled[1].reason, 'tracking-loss', 'the cancellation reason')
  f:update(pointer, { target }, { buttons = { left = true, middle = true } })
  f:update(pointer, { target }, { buttons = { middle = true } })
  expect.equal(#f:matching('press', pointer, target), 2, 'reacquisition cannot create held-button presses')
  f:update(pointer, { target })
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 3, 'a fresh press after all-up resumes delivery')
  f:close()
end)

test('a drop is emitted once while the listener sees the ending grab', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'carried'
  target.pose = lovr.math.newMat4():translate(0, 0, -1)
  function target:setPose(pose: Mat4)
    self.pose:set(pose)
  end
  local drops = f.session:observe(require('@lunette-contracts/drops').capability)
  local heard: { { read surface: fixture.Surface, read pointer: typeof(pointer) } } = {}
  drops.service:onDropped(drops.context, {
    run = function(event: { read surface: fixture.Surface, read pointer: typeof(pointer) })
      heard[#heard + 1] = event
      expect.equal(event.pointer.grabbed, target, 'the listener can inspect the ending grab')
    end,
  })
  expect.truthy(pointer:beginGrab(target, lovr.math.newMat4()), 'the grab starts')
  expect.truthy(pointer:endGrab(), 'the grab ends')
  expect.equal(#heard, 1, 'exactly one drop is emitted')
  expect.equal(heard[1].surface, target, 'the dropped surface')
  expect.equal(heard[1].pointer, pointer, 'the dropping pointer')
  expect.equal(pointer.grabbed, nil, 'the grab clears')
  expect.falsy(pointer:endGrab(), 'nothing is carried twice')
  expect.equal(#heard, 1, 'a second end emits no drop')
  f:close()
end)

test('grip cancels a UI capture before a panel moves and cannot reactivate its held trigger', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'movable'
  target.grabbable = true
  target.pose = lovr.math.newMat4():translate(0, 0, -1)
  target.width, target.height = 1, 1
  local moved = 0
  function target:setPose(pose: Mat4)
    expect.equal(#f:matching('cancel', pointer, target), 1, 'capture cancels before the first grab motion')
    moved += 1
    self.pose:set(pose)
  end
  f:update(pointer, { target }, { buttons = { left = true } })
  f:update(pointer, { target }, { grip = true, buttons = { left = true } })
  expect.equal(f:matching('cancel', pointer, target)[1].reason, 'grab', 'the grab cancels the UI gesture')
  expect.equal(pointer.grabbed, target, 'the grip grabs')
  f:update(pointer, { target }, { grip = true, buttons = { left = true }, x = 0.2 })
  expect.truthy(moved > 0, 'a held grip moves the surface')
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 1, 'ending a grab cannot restart its held trigger')
  expect.equal(#f:matching('release', pointer, target), 0, 'a grab cancel cannot activate a UI release')
  f:close()
end)

return test
