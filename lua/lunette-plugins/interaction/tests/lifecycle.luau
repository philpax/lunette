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

test('pointer destruction attempts every cancellation before reporting failures', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  local attempts = {}
  function target:onPointer(event)
    if event.kind == 'cancel' then
      attempts[#attempts + 1] = event.button
      expect.truthy(pointer.dead, 'destruction commits the dead state before callbacks')
      error('fixture cancellation failure ' .. event.button)
    end
  end
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  expect.raises(function()
    pointer:destroy()
  end, 'fixture cancellation failure', 'combined cancellation failures reach the caller')
  expect.equal(table.concat(attempts, '+'), 'left+right', 'every inverse runs despite the first failure')
  expect.falsy(pointer:destroy(), 'failed callbacks cannot retain active gestures')
  expect.equal(#f.service:pointers(), 0, 'the dead pointer leaves the registry')
  f:close()
end)

test('provider withdrawal cancels every pointer independently and retained handles remain inert', function()
  local f = fixture()
  local first, second, target = f:pointer(), f:pointer(), f:surface 'plate'
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { right = true } })
  f.session.instances.interaction:disable()
  expect.truthy(first.dead and second.dead, 'both retained pointers end with the provider')
  local cancelled = f:matching('cancel', nil, target)
  expect.equal(#cancelled, 2, 'provider cleanup attempts both pointers')
  -- The runtime drains dependent owners while their provider remains active, without exposing the owner's stop cause.
  for _, event in ipairs(cancelled) do
    expect.equal(event.reason, 'pointer-destroyed', 'the owner effect destroys the pointer before provider teardown')
  end
  local count = #f.events
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { right = true } })
  expect.equal(#f.events, count, 'ended pointers cannot continue into another activation')
  f:close()
end)

test('cancellation callback failure does not prevent other pointers from ending with the provider', function()
  local f = fixture()
  local first, second, target = f:pointer(), f:pointer(), f:surface 'plate'
  local attempts = 0
  function target:onPointer(event)
    if event.kind == 'cancel' then
      attempts += 1
      error 'fixture provider cancellation failure'
    end
  end
  f:update(first, { target }, { buttons = { left = true } })
  f:update(second, { target }, { buttons = { right = true } })
  f.session.instances.interaction:disable()
  expect.truthy(first.dead and second.dead, 'both pointers end despite an earlier cancellation failure')
  expect.equal(attempts, 2, 'every pointer cancellation runs')
  local reports = testing.takeReports()
  expect.truthy(#reports > 0, 'the provider cleanup failure is reported')
  for _, report in ipairs(reports) do
    expect.truthy(report:find('fixture provider cancellation failure', 1, true), 'the report retains callback context')
  end
  f:close()
end)

test('cancelling a surface clears all of its buttons before callbacks can reenter cancellation', function()
  local f = fixture()
  local pointer, target = f:pointer(), f:surface 'plate'
  local cancellations = 0
  local record = target.onPointer
  function target:onPointer(event)
    record(self, event)
    if event.kind == 'cancel' then
      cancellations += 1
      pointer:cancel(target, 'hidden')
    end
  end
  f:update(pointer, { target }, { buttons = { left = true, right = true } })
  pointer:cancel(target, 'hidden')
  expect.equal(cancellations, 2, 'reentrant cancellation cannot duplicate another pending inverse')
  expect.equal(#f:matching('release', pointer, target), 0, 'cleared capture cannot activate release')
  f:update(pointer, { target })
  f:update(pointer, { target }, { buttons = { left = true } })
  expect.equal(#f:matching('press', pointer, target), 3, 'a released pointer starts a fresh gesture')
  f:close()
end)

test('drop reentry finalizes only the ending grab and emits it once', function()
  for _, operation in ipairs { 'focus', 'endGrab', 'new-grab' } do
    local f = fixture()
    local pointer, target, replacement = f:pointer(), f:surface 'carried', f:surface 'replacement'
    for _, surface in ipairs { target, replacement } do
      surface.pose = lovr.math.newMat4():translate(0, 0, -1)
      surface.setPose = function(self, pose)
        self.pose:set(pose)
      end
    end
    local drops = f.session:observe(require('@lunette-contracts/drops').capability)
    local count = 0
    drops.service:onDropped(drops.context, {
      run = function(event)
        count += 1
        expect.equal(event.pointer.grabbed, target, 'the listener can inspect the ending grab')
        if count == 1 then
          if operation == 'focus' then
            pointer:focus(nil)
          elseif operation == 'endGrab' then
            expect.falsy(pointer:endGrab(), 'recursive endGrab does not announce the ending grab again')
          else
            expect.truthy(pointer:beginGrab(replacement, lovr.math.newMat4()), 'the listener starts a new grab')
          end
        end
      end,
    })
    expect.truthy(pointer:beginGrab(target, lovr.math.newMat4()), 'the original grab starts')
    expect.truthy(pointer:endGrab(), 'the original grab ends')
    expect.equal(count, 1, 'exactly one original drop is emitted')
    expect.equal(pointer.grabbed, if operation == 'new-grab' then replacement else nil, 'only the original grab clears')
    f:close()
  end
end)

for _, operation in ipairs { 'withdraw', 'destroy' } do
  test('a drop listener can ' .. operation .. ' without announcing the ending grab twice', function()
    local f = fixture()
    local pointer, target, ui = f:pointer(), f:surface 'carried', f:surface 'ui'
    target.pose = lovr.math.newMat4():translate(0, 0, -1)
    function target:setPose(pose)
      self.pose:set(pose)
    end
    local drops = f.session:observe(require('@lunette-contracts/drops').capability)
    local downstream = f.session:observe(require('@lunette-contracts/drops').capability)
    local notifications, received = 0, 0
    drops.service:onDropped(drops.context, {
      run = function(event)
        notifications += 1
        if notifications == 1 then
          expect.equal(event.pointer.grabbed, target, 'the first listener sees the ending grab')
          if operation == 'withdraw' then
            pointer:withdraw()
          else
            expect.truthy(pointer:destroy(), 'the listener destroys the pointer')
          end
        end
      end,
    })
    downstream.service:onDropped(downstream.context, {
      run = function(event)
        expect.equal(event.surface, target, 'the downstream notification names the ending surface')
        expect.equal(event.pointer, pointer, 'the downstream notification names the original pointer')
        received += 1
      end,
    })
    expect.truthy(pointer:beginGrab(target, lovr.math.newMat4()), 'the original grab starts')
    pointer:hover(ui)
    pointer:setButton { button = 'left', pressed = true, surface = ui }
    pointer:setButton { button = 'right', pressed = true, surface = ui }
    expect.truthy(pointer:endGrab(), 'the original grab ends')
    expect.equal(notifications, 1, 'the reentrant listener receives exactly one original drop')
    expect.equal(received, 1, 'the independent downstream listener receives exactly one original drop')
    expect.equal(pointer.grabbed, nil, 'teardown clears the carried surface')
    expect.equal(pointer.hovered, nil, 'teardown clears hover independently of drop suppression')
    expect.equal(#f:matching('cancel', pointer, ui), 2, 'teardown still cancels every UI capture')
    expect.equal(#f:matching('release', pointer, ui), 0, 'teardown cannot activate a UI release')
    if operation == 'destroy' then
      expect.truthy(pointer.dead, 'destruction commits the dead state')
      expect.equal(#f.service:pointers(), 0, 'destruction removes the pointer from the registry')
    else
      expect.falsy(pointer.dead, 'withdrawal preserves the pointer')
      expect.falsy(pointer:endGrab(), 'withdrawal leaves no retained grab')
    end
    f:close()
    expect.equal(received, 1, 'later cleanup cannot announce the original grab again')
  end)
end

test('a drop listener can begin and withdraw a distinct grab without suppressing its notification', function()
  for _, sameSurface in ipairs { false, true } do
    local f = fixture()
    local pointer, original = f:pointer(), f:surface 'original'
    local replacement = if sameSurface then original else f:surface 'replacement'
    for _, target in ipairs { original, replacement } do
      target.pose = lovr.math.newMat4():translate(0, 0, -1)
      function target:setPose(pose)
        self.pose:set(pose)
      end
    end
    local drops = f.session:observe(require('@lunette-contracts/drops').capability)
    local downstream = f.session:observe(require('@lunette-contracts/drops').capability)
    local notifications, received = {}, {}
    drops.service:onDropped(drops.context, {
      run = function(event)
        notifications[#notifications + 1] = event.surface
        if #notifications == 1 then
          expect.equal(pointer.grabbed, original, 'the listener can inspect the original grab')
          expect.truthy(pointer:beginGrab(replacement, lovr.math.newMat4()), 'the listener starts a distinct grab')
          pointer:withdraw()
        end
      end,
    })
    downstream.service:onDropped(downstream.context, {
      run = function(event)
        expect.equal(event.pointer, pointer, 'both notifications retain the actual pointer')
        received[#received + 1] = event.surface
      end,
    })
    expect.truthy(pointer:beginGrab(original, lovr.math.newMat4()), 'the original grab starts')
    expect.truthy(pointer:endGrab(), 'the original grab ends')
    expect.equal(#notifications, 2, 'both distinct grabs announce once to the initiating listener')
    expect.equal(notifications[1], original, 'the first announcement is the original grab')
    expect.equal(notifications[2], replacement, 'withdrawal announces the callback-created grab')
    expect.equal(#received, 2, 'the independent listener receives both distinct notifications')
    expect.equal(received[1], replacement, 'the nested withdrawal completes before the original delivery resumes')
    expect.equal(received[2], original, 'the original delivery resumes exactly once')
    expect.equal(pointer.grabbed, nil, 'withdrawal clears the callback-created grab')
    f:close()
    expect.equal(#received, 2, 'later cleanup cannot duplicate either grab')
  end
end)

test('a grip-up sample cannot release a capture created by its drop listener', function()
  local f = fixture()
  local pointer, carried, ui = f:pointer(), f:surface 'carried', f:surface 'ui'
  carried.grabbable = true
  carried.pose = lovr.math.newMat4():translate(0, 0, -1)
  function carried:setPose(pose)
    self.pose:set(pose)
  end
  local drops = f.session:observe(require('@lunette-contracts/drops').capability)
  local count = 0
  drops.service:onDropped(drops.context, {
    run = function()
      count += 1
      if count == 1 then
        pointer:hover(ui)
        pointer:setButton { button = 'left', pressed = true, surface = ui }
      end
    end,
  })
  f:update(pointer, { carried }, { grip = true })
  f:update(pointer, { carried })
  expect.equal(#f:matching('press', pointer, ui), 1, 'the drop listener creates a fresh capture')
  expect.equal(#f:matching('release', pointer, ui), 0, 'the older all-up sample cannot release the new capture')
  pointer:setButton { button = 'left', pressed = false }
  expect.equal(#f:matching('release', pointer, ui), 1, 'a later up releases the listener capture')
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

test('surface callbacks that destroy a pointer stop the remaining press and scroll continuation', function()
  for _, kind in ipairs { 'enter', 'move', 'press' } do
    local f = fixture()
    local pointer, target = f:pointer(), f:surface 'plate'
    local record = target.onPointer
    function target:onPointer(event)
      record(self, event)
      if event.kind == kind then
        event.pointer:destroy()
      end
    end
    f:update(pointer, { target }, { buttons = { left = true, right = true }, scrollY = 1 })
    expect.truthy(pointer.dead, 'the callback ends the pointer')
    expect.equal(#f:matching('press', pointer, target, 'right'), 0, 'a replacement button continuation never runs')
    if kind == 'enter' or kind == 'move' then
      expect.equal(#f:matching('press', pointer, target), 0, 'destroyed hover cannot continue to press')
      expect.equal(#f:matching('scroll', pointer, target), 0, 'destroyed hover cannot continue to scroll')
    else
      expect.equal(#f:matching('press', pointer, target, 'left'), 1, 'the original press runs once')
      expect.equal(#f:matching('cancel', pointer, target, 'left'), 1, 'destruction cancels the recorded press')
    end
    f:close()
  end
end)

test('geometry and native callbacks that destroy a pointer stop stale input delivery', function()
  for _, boundary in ipairs { 'raycast', 'sink', 'project', 'native-motion', 'native-press' } do
    local f = fixture()
    local pointer, target = f:pointer(), f:surface 'plate'
    if boundary == 'project' then
      f:update(pointer, { target }, { buttons = { left = true } })
    end
    local record = target[boundary]
    if boundary == 'raycast' or boundary == 'sink' or boundary == 'project' then
      target[boundary] = function(self, ...)
        pointer:destroy()
        return if record then record(self, ...) else nil
      end
    else
      local sink = {
        dead = false,
        domain = 'host',
        monitor = { id = 'reentrant-native' },
        focus = function()
          return true
        end,
        leave = function() end,
        scroll = function() end,
        pointer = function()
          if boundary == 'native-motion' then
            pointer:destroy()
          end
        end,
        button = function(_self, _button, down)
          if boundary == 'native-press' and down then
            pointer:destroy()
          end
        end,
      }
      function target:sink()
        return sink
      end
    end
    local presses = #f:matching('press', pointer, target)
    f:update(pointer, { target }, { buttons = { left = true, right = true }, scrollY = 1 })
    expect.truthy(pointer.dead, 'the boundary ends the pointer')
    expect.equal(#f:matching('press', pointer, target), presses, 'stale surface presses never run')
    expect.equal(#f:matching('scroll', pointer, target), 0, 'stale surface scrolling never runs')
    f:close()
  end
end)

return test
