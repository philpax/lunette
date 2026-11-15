local testing = require '@testing'
local lunette = require '@lunette'
local panelsContract = require '@lunette-contracts/panels'
local interaction = require '@lunette-contracts/interaction'
local expect = testing.expect
local test = testing.suite()

local function start(kind: panelsContract.Kind): (
  testing.Native,
  testing.Session,
  testing.Context,
  any,
  panelsContract.Panel,
  interaction.Pointer,
  (boolean?, number?) -> ()
)
  local native = testing.native()
  local seat = require('@lunette').newSeat { name = 'lock-test' }
  require('@lunette').defaultSeat = function(): lunette.Seat
    return seat
  end
  local session = testing.start { 'theme', 'panels', 'drops', 'focus', 'interaction' }
  local panels = session:observe(panelsContract.capability)
  local pointers = session:observe(interaction.capability)
  local source = if kind == 'monitor' then native.newMonitor 'display' else native.newWindow(51)
  local options = { pose = lovr.math.newMat4():translate(0, 0, -2), height = 1 }
  local panel = if kind == 'monitor'
    then panels.service:fromMonitor(panels.context, source, options)
    else panels.service:fromWindow(panels.context, source, options)
  local pointer = pointers.service:newPointer(pointers.context)
  local function update(held: boolean?, scroll: number?)
    pointer:update({
      origin = vector.pack(0, 0, 0),
      direction = vector.pack(0, 0, -1),
      pose = lovr.math.newMat4(),
      buttons = { left = held or false },
      grip = false,
      scrollY = scroll,
      dt = 1,
    }, { panel })
  end
  return native, session, panels.context, source, panel, pointer, update
end

for _, kind in { 'window', 'monitor' } do
  test(kind .. ' lock releases retained input and denies public pointer routes until a fresh edge', function()
    local native, session, owner, source, panel, pointer, update = start(kind)
    update(true)
    local before = #native.events.input
    panel:setLocked(owner, true)
    expect.truthy(#native.events.input > before, 'held button and hover release immediately')
    local released = false
    for index = before + 1, #native.events.input do
      local event = native.events.input[index]
      if event[1] == 'button' and event[3] == false then
        released = true
      end
    end
    expect.truthy(released, 'the held native button releases')
    local locked = #native.events.input
    update(true, 1)
    pointer:hover(panel)
    pointer:setButton { button = 'right', pressed = true, sink = source.sink, surface = panel }
    pointer:setButton { button = 'middle', pressed = true, sink = source.sink }
    pointer:focus(source.sink)
    expect.equal(#native.events.input, locked, 'locked content emits no native input')
    panel:setLocked(owner, false)
    update(true)
    local presses = 0
    for index = locked + 1, #native.events.input do
      local event = native.events.input[index]
      if event[1] == 'button' and event[3] then
        presses += 1
      end
    end
    expect.equal(presses, 0, 'unlock does not replay a held press')
    update(false)
    update(true)
    expect.equal(native.events.input[#native.events.input][1], 'button', 'a fresh press reaches content')
    session:close()
  end)
end

test('leaving a monitor for its titlebar preserves pointer interaction', function()
  local native, session, _, source, _, pointer, update = start 'monitor'
  expect.falsy(source.sink:leave(), 'the native host cannot withdraw its cursor')
  update(false)
  local presses = 0
  local titlebar = {
    dead = false,
    onPointer = function(_: any, event: interaction.PointerEvent)
      if event.kind == 'press' then
        presses += 1
      end
    end,
  }
  pointer:hover(titlebar)
  pointer:setButton { pressed = true, surface = titlebar }
  expect.equal(presses, 1, 'the titlebar remains usable after leaving host content')
  expect.equal(#native.events.reported, 0, 'unsupported host leave is not a cleanup failure')
  session:close()
end)

test('a refused window leave fails the pointer closed', function()
  local native, session, _, source, _, pointer, update = start 'window'
  update(false)
  source.sink.leave = function(): boolean
    return false
  end
  expect.raises(function()
    pointer:hover(nil)
  end, 'sink refused leave', 'window withdrawal refusal remains an error')
  local before = #native.events.input
  update(true)
  expect.equal(#native.events.input, before, 'a failed window inverse prevents later delivery')
  expect.equal(#native.events.reported, 0, 'the public caller receives the cleanup error')
  session:close()
end)

test('locked content occludes a surface behind it while preserving spatial grabs', function()
  local _, session, owner, _, panel, pointer = start 'window'
  panel:setLocked(owner, true)
  local presses = 0
  local behind = {
    dead = false,
    raycast = function(): (number, number, number)
      return 0.5, 0.5, 3
    end,
    onPointer = function(_: any, event: interaction.PointerEvent)
      if event.kind == 'press' then
        presses += 1
      end
    end,
  }
  local frame = {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4(),
    buttons = { left = true },
    grip = false,
  }
  pointer:update(frame, { behind, panel })
  expect.equal(pointer.hovered, panel, 'the locked hit wins')
  expect.equal(presses, 0, 'no clickthrough')
  frame.buttons = {}
  frame.grip = true
  pointer:update(frame, { behind, panel })
  expect.equal(pointer.grabbed, panel, 'spatial grab stays available')
  session:close()
end)

test('reentrant unlock during pointer cleanup cannot send fresh input', function()
  local native, session, owner, source, panel, pointer, update = start 'window'
  update(true)
  local original = source.sink.button
  source.sink.button = function(
    self: any,
    button: lunette.PointerButton,
    pressed: boolean,
    seat: lunette.Seat?
  ): boolean
    if not pressed then
      panel:setLocked(owner, false)
      pointer:setButton { button = 'right', pressed = true, sink = source.sink }
      pointer:focus(source.sink)
    end
    return original(self, button, pressed, seat)
  end
  local before = #native.events.input
  panel:setLocked(owner, true)
  for index = before + 1, #native.events.input do
    local event = native.events.input[index]
    expect.falsy(event[1] == 'button' and event[3], 'cleanup sends only native releases')
  end
  session:close()
end)

test('a refused lock inverse fails the pointer closed after unlock', function()
  local native, session, owner, source, panel, pointer, update = start 'window'
  update(true)
  local original = source.sink.button
  source.sink.button = function(
    self: any,
    button: lunette.PointerButton,
    pressed: boolean,
    seat: lunette.Seat?
  ): boolean
    if not pressed then
      return false
    end
    return original(self, button, pressed, seat)
  end
  panel:setLocked(owner, true)
  local reported = native.events.reported
  expect.truthy(#reported > 0, 'cleanup refusal is reported')
  panel:setLocked(owner, false)
  local before = #native.events.input
  update(false)
  update(true)
  pointer:setButton { pressed = true, sink = source.sink }
  expect.equal(#native.events.input, before, 'an unresolved pointer cannot resume delivery')
  session:close()
end)

test('a transform-locked panel refuses grip and trigger grabs while content input still works', function()
  local native, session, owner, source, panel, pointer, update = start 'window'
  expect.truthy(panel:setTransformLocked(owner, true), 'the lock applies')
  update(false)
  local before = #native.events.input
  pointer:setButton { pressed = true, sink = source.sink, surface = panel }
  expect.truthy(#native.events.input > before, 'content input still reaches the window')

  local frame = {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4():translate(0, 0, -1),
    buttons = {},
    grip = true,
  }
  pointer:update(frame, { panel })
  expect.falsy(pointer.grabbed, 'a grip does not grab the locked panel')

  local titlebar = {
    dead = false,
    pose = lovr.math.newMat4():translate(0, 0.6, -2),
    width = 1,
    height = 0.2,
    raycast = function(): (number, number, number)
      return 0.5, 0.5, 3
    end,
    triggerGrabs = function(): boolean
      return true
    end,
    grabTarget = function(): any
      return panel
    end,
  }
  local trigger = {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4():translate(0, 0, -1),
    buttons = { left = true },
    grip = false,
  }
  pointer:update(trigger, { titlebar, panel })
  expect.falsy(pointer.grabbed, 'a titlebar trigger drag is refused while the target is locked')
  session:close()
end)

test('a two-handed resize of a transform-locked panel is refused', function()
  local _, session, owner, _, panel, pointer, update = start 'window'
  update(false)
  expect.truthy(pointer:beginGrab(panel, lovr.math.newMat4():translate(0, 0, -1)), 'the first hand grabs')
  expect.truthy(panel:setTransformLocked(owner, true), 'the lock applies to the held panel')
  local width = panel.width
  pointer:scaleWith(lovr.math.newMat4():translate(1, 0, -1))
  expect.equal(panel.width, width, 'the width does not change')
  session:close()
end)

test('a grab in flight ends when the panel is transform-locked', function()
  local _, session, owner, _, panel, pointer, update = start 'window'
  update(false)
  local frame = {
    origin = vector.pack(0, 0, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4():translate(0, 0, -1),
    buttons = {},
    grip = true,
  }
  pointer:update(frame, { panel })
  expect.equal(pointer.grabbed, panel, 'the panel is held before the lock')
  expect.truthy(panel:setTransformLocked(owner, true), 'the lock applies')
  pointer:update(frame, { panel })
  expect.falsy(pointer.grabbed, 'the held grab detaches when the lock engages')
  session:close()
end)

test('a transform-locked panel leaves its content interactive', function()
  local native, session, owner, source, panel, pointer, update = start 'window'
  expect.truthy(panel:setTransformLocked(owner, true), 'the lock applies')
  update(false)
  local before = #native.events.input
  pointer:setButton { button = 'right', pressed = true, sink = source.sink, surface = panel }
  expect.truthy(#native.events.input > before, 'a content press still reaches the window')
  session:close()
end)

return test
