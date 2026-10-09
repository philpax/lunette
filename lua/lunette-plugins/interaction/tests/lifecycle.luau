local testing = require '@testing'
local vocabulary = require '@lunette-contracts/vocabulary'
local fixture = require './support/protocol'
local expect = testing.expect
local test = testing.suite()

test('tracking loss cancels captures and quarantines all held buttons until an all-up tracked sample', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  pointer:withdraw()
  expect.equal(#f:matching('release', pointer, target), 0, 'tracking loss is not release')
  local cancelled = f:matching('cancel', pointer, target)
  expect.equal(#cancelled, 2, 'both active buttons cancel')
  expect.equal(cancelled[1].reason, 'tracking-loss', 'the cancellation reason')
  f:update(pointer, { target }, { buttons = { left = true, middle = true } })
  f:update(pointer, { target }, { buttons = { left = true } })
  f:update(pointer, { target }, { buttons = { middle = true } })
  expect.equal(#f:matching('press', pointer, target), 2, 'reacquisition cannot create new held-button presses')
  f:update(pointer, { target })
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 3, 'a fresh press after all-up resumes delivery')
  f:close()
end)

test('a custom driver resumes only after every button is reported up through the primitives', function()
  local provider = require '@lunette-plugins/interaction'
  local f = fixture(provider.define {
    name = 'primitive-driver',
    drive = function(pointer, frame, surfaces)
      local target = surfaces[1]
      pointer:hover(target)
      for _, button in ipairs(vocabulary.POINTER_BUTTONS) do
        pointer:setButton { button = button, pressed = frame.buttons[button] == true, surface = target }
      end
    end,
  })
  local pointer, target = f:pointer(), f:surface 'plate'
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  pointer:withdraw()
  expect.equal(#f:matching('cancel', pointer, target), 2, 'both primitive captures cancel')
  f:update(pointer, { target }, { buttons = { middle = true } })
  f:update(pointer, { target }, { buttons = { right = true } })
  expect.equal(#f:matching('press', pointer, target), 2, 'partially released samples remain quarantined')
  f:update(pointer, { target })
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 3, 'a complete all-up report permits a fresh primitive press')
  f:update(pointer, { target })
  f:close()
end)

test('provider withdrawal ends every pointer despite a cancellation failure and leaves the handles inert', function()
  local f = fixture()
  local first, second, target = f:pointer(), f:pointer(), f:surface 'plate'
  local record = target.onPointer
  function target:onPointer(event)
    record(self, event)
    if event.kind == 'cancel' then
      error 'fixture provider cancellation failure'
    end
  end
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { right = true } })
  f.session.instances.interaction:disable()
  expect.truthy(first.dead and second.dead, 'both pointers end despite an earlier cancellation failure')
  local cancelled = f:matching('cancel', nil, target)
  expect.equal(#cancelled, 2, 'provider cleanup attempts both pointers')
  -- The runtime drains dependent owners while their provider remains active, without exposing the owner's stop cause.
  for _, event in ipairs(cancelled) do
    expect.equal(event.reason, 'pointer-destroyed', 'the owner effect destroys the pointer before provider teardown')
  end
  local reports = testing.takeReports()
  expect.truthy(#reports > 0, 'the provider cleanup failure is reported')
  for _, report in ipairs(reports) do
    expect.truthy(report:find('fixture provider cancellation failure', 1, true), 'the report retains callback context')
  end
  local count = #f.events
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { right = true } })
  expect.equal(#f.events, count, 'ended pointers cannot continue into another activation')
  f:close()
end)

test('a drop is emitted once while the listener sees the ending grab', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'carried'
  target.pose = lovr.math.newMat4():translate(0, 0, -1)
  function target:setPose(pose)
    self.pose:set(pose)
  end
  local drops = f.session:observe(require('@lunette-contracts/drops').capability)
  local count = 0
  drops.service:onDropped(drops.context, {
    run = function(event)
      count += 1
      expect.equal(event.pointer.grabbed, target, 'the listener can inspect the ending grab')
    end,
  })
  expect.truthy(pointer:beginGrab(target, lovr.math.newMat4()), 'the grab starts')
  expect.truthy(pointer:endGrab(), 'the grab ends')
  expect.equal(count, 1, 'exactly one drop is emitted')
  expect.equal(pointer.grabbed, nil, 'the grab clears')
  f:close()
end)

test('grip cancels a UI capture before a panel moves and cannot reactivate its held trigger', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'movable'
  target.grabbable = true
  target.pose = lovr.math.newMat4():translate(0, 0, -1)
  target.width, target.height = 1, 1
  local cancelled, moved = 0, 0
  function target:setPose(pose)
    expect.equal(cancelled, 1, 'capture cancels before the first grab motion')
    moved += 1
    self.pose:set(pose)
  end
  local record = target.onPointer
  function target:onPointer(event)
    record(self, event)
    if event.kind == 'cancel' then
      expect.equal(event.reason, 'grab', 'the spatial grab reason')
      cancelled += 1
    end
  end
  f:update(pointer, { target }, { buttons = { left = true } })
  f:update(pointer, { target }, { grip = true, buttons = { left = true } })
  expect.equal(cancelled, 1, 'beginning a grab cancels the active UI gesture')
  expect.equal(pointer.grabbed, target, 'the grip retains spatial grabbing')
  f:update(pointer, { target }, { grip = true, buttons = { left = true }, x = 0.2 })
  expect.truthy(moved > 0, 'a held grip moves the surface')
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 1, 'ending a grab cannot restart its held trigger')
  expect.equal(#f:matching('release', pointer, target), 0, 'a grab cancel cannot activate a UI release')
  f:update(pointer, { target })
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 2, 'a fresh trigger gesture resumes UI delivery')
  f:update(pointer, { target })
  f:close()
end)

test('a surface callback that destroys a pointer on press stops the remaining continuation', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  local record = target.onPointer
  function target:onPointer(event)
    record(self, event)
    if event.kind == 'press' then
      event.pointer:destroy()
    end
  end
  f:update(pointer, { target }, { buttons = { left = true, right = true }, scrollY = 1 })
  expect.truthy(pointer.dead, 'the callback ends the pointer')
  expect.equal(#f:matching('press', pointer, target, 'right'), 0, 'a replacement button continuation never runs')
  expect.equal(#f:matching('press', pointer, target, 'left'), 1, 'the original press runs once')
  expect.equal(#f:matching('cancel', pointer, target, 'left'), 1, 'destruction cancels the recorded press')
  f:close()
end)

return test
