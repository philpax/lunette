local testing = require '@testing'
local plugin = require '@lunette-plugin'
local controller = require '@lunette-plugins/desktop/manager/controller'
local managerConfig = require '@lunette-plugins/desktop/manager/config'
local frameContract = require '@lunette-contracts/frame'
local interactionContract = require '@lunette-contracts/interaction'
local interaction = require '@lunette-plugins/interaction'
local drops = require '@lunette-plugins/drops'
local focus = require '@lunette-plugins/focus'
local boot = require './support/boot'
local expect = testing.expect
local test = testing.suite()

local function fakePointer()
  return { cancel = function() end }
end

local function send(offered, kind, pointer, x, y)
  if kind == 'release' and x == nil then
    x, y = pointer.x, pointer.y
  elseif x ~= nil and y ~= nil then
    pointer.x, pointer.y = x, y
  end
  offered:onPointer {
    kind = kind,
    pointer = pointer,
    button = if kind == 'press' or kind == 'release' or kind == 'move' then 'left' else nil,
    x = x,
    y = y,
    captured = kind ~= 'leave',
    inside = kind ~= 'leave',
  }
end

test('projected manager toggles, offers a raycastable movable surface, and releases on shutdown', function()
  local running, fake, all = boot()
  expect.equal(#all(), 0, 'initially hidden')
  lovr.keypressed('f10', 0, false)
  local offered = all()[1]
  expect.truthy(offered, 'toggle exposes surface')
  local x, y, distance = offered:raycast(vector.pack(0, 1.4, 0), vector.pack(0, 0, -1))
  expect.truthy(x and y and distance, 'projected hit')
  expect.truthy(math.abs(x - 640) < 0.001, 'logical center x')
  local pointer = fakePointer()
  send(offered, 'move', pointer, x, y)
  send(offered, 'press', pointer, x, y)
  send(offered, 'release', pointer)
  offered:setPose(lovr.math.mat4():translate(0.5, 1.4, -1.2))
  expect.equal(offered:raycast(vector.pack(-1, 1.4, 0), vector.pack(0, 0, -1)), nil, 'moved away')
  lovr.update(0.016)
  lovr.draw(fake.events.pass)
  expect.truthy(#fake.events.draw > 0, 'projected graph draws')
  lovr.keypressed('f10', 0, true)
  expect.equal(#all(), 1, 'key repeat does not retoggle')
  lovr.keypressed('f10', 0, false)
  expect.equal(#all(), 0, 'toggle hides surface')
  running.runtime:close()
  expect.equal(offered:raycast(vector.pack(0.5, 1.4, 0), vector.pack(0, 0, -1)), nil, 'retained surface inert')
  fake.assertResourcesReleased()
end)

test('management surface keeps its direct dependencies protected but not inspection-only providers', function()
  local running = boot { visible = true }
  local protected = {}
  for _, entry in running.service:entries() do
    protected[entry.id] = entry.protected
  end
  expect.equal(protected.frame, true, 'frame protected')
  expect.equal(protected.surfaces, true, 'surface broker protected')
  expect.equal(protected.observer, false, 'unrelated consumer mutable')
  running.service:disable 'observer'
  expect.equal(running.runtime:snapshot().instances[1] ~= nil, true, 'runtime remains available')
  running.runtime:close()
end)

test('another pointer cannot move cancel or replace a captured graph press', function()
  local running, _, all, state = boot { visible = true }
  local offered = all()[1]
  local first, second = fakePointer(), fakePointer()
  local camera = state.view.camera
  send(offered, 'press', first, 1, 1)
  send(offered, 'move', second, 100, 100)
  send(offered, 'press', second, 100, 100)
  send(offered, 'leave', second)
  send(offered, 'release', second)
  offered:onPointer {
    kind = 'cancel',
    pointer = second,
    button = 'left',
    reason = 'disabled',
    captured = true,
    inside = false,
  }
  local afterOther, dragging = state.view.camera, state.view.dragging
  send(offered, 'move', first, 21, 31)
  local moved = state.view.camera
  send(offered, 'release', first)
  local ended = state.view.dragging
  local released = state.view.camera
  send(offered, 'move', second, 80, 80)
  local hovered = state.view.camera
  send(offered, 'press', second, 1, 1)
  send(offered, 'move', second, 11, 11)
  send(offered, 'release', second)
  local movedSecond = state.view.camera
  running.runtime:close()
  expect.equal(afterOther.x, camera.x, 'another pointer cannot pan')
  expect.truthy(dragging, 'another pointer cannot cancel')
  expect.near((camera.x - moved.x) * camera.zoom, 20, 1e-5, 'the captured pointer moves x')
  expect.near((camera.y - moved.y) * camera.zoom, 30, 1e-5, 'the captured pointer moves y')
  expect.equal(ended, nil, 'the captured pointer releases')
  expect.equal(hovered.x, released.x, 'hover after release cannot pan')
  expect.near((released.x - movedSecond.x) * released.zoom, 10, 1e-5, 'a second pointer can press after release')
end)

test('hiding clears pointer capture and a later hover cannot resume its drag', function()
  local running, _, all, state = boot { visible = true }
  local offered = all()[1]
  local pointer = fakePointer()
  send(offered, 'press', pointer, 1, 1)
  lovr.keypressed('f10', 0, false)
  local hiddenDrag = state.view.dragging
  lovr.keypressed('f10', 0, false)
  local camera = state.view.camera
  send(offered, 'move', pointer, 30, 30)
  local hovered = state.view.camera
  send(offered, 'press', fakePointer(), 1, 1)
  local nextDrag = state.view.dragging
  running.runtime:close()
  expect.equal(hiddenDrag, nil, 'hiding cancels the drag')
  expect.equal(hovered.x, camera.x, 'hover cannot resume the hidden press')
  expect.truthy(nextDrag, 'capture is available again')
end)

test('shutdown invalidates retained surface methods and clears the pending gesture', function()
  local running, _, all, state = boot { visible = true }
  local offered = all()[1]
  local pointer = fakePointer()
  send(offered, 'move', pointer, 1, 1)
  send(offered, 'press', pointer, 1, 1)
  local position = vector.pack(offered.pose:getPosition())
  local camera = state.view.camera
  running.runtime:close()
  expect.equal(offered.dead, true, 'the public surface is dead')
  expect.equal(state.view.dragging, nil, 'capture is cancelled at shutdown')
  offered:setPose(lovr.math.newMat4():translate(8, 9, 10))
  send(offered, 'move', pointer, 20, 30)
  send(offered, 'press', pointer, 20, 30)
  send(offered, 'leave', pointer)
  send(offered, 'release', pointer)
  expect.equal(vector.pack(offered.pose:getPosition()), position, 'retained pose setter is inert')
  expect.equal(state.view.camera.x, camera.x, 'retained input cannot pan')
  expect.equal(state.view.dragging, nil, 'retained input cannot start a gesture')
end)

test('a real interaction pointer drops a withdrawn manager on its next update', function()
  local pointer
  local observer = plugin.define {
    name = 'pointer-observer',
    requires = { interaction = interactionContract.capability },
    init = function(context)
      pointer = context:require(interactionContract.capability):newPointer(context)
    end,
  }
  local running, _, all = boot({ visible = true }, {
    { id = 'drops', definition = drops.definition },
    { id = 'focus', definition = focus.definition },
    { id = 'interaction', definition = interaction.definition },
    { id = 'pointer-observer', definition = observer },
  }, { 'frame', 'surfaces' })
  local offered = all()[1]
  expect.truthy(pointer:beginGrab(offered, lovr.math.newMat4()), 'the real pointer grabs the manager')
  running.service:disable 'desktop/manager'
  pointer:update({
    origin = vector.pack(0, 1.4, 0),
    direction = vector.pack(0, 0, -1),
    pose = lovr.math.newMat4(),
    buttons = {},
    grip = true,
    dt = 0.016,
  }, all())
  local grabbed = pointer.grabbed
  running.runtime:close()
  expect.equal(grabbed, nil, 'dead surface is dropped while grip remains held')
end)

test('manager dimensions reject a short canvas and accept usable minimum and maximum aspects', function()
  expect.raises(function()
    managerConfig.schema.parse({ width = 5, height = 0.1, pixels = 800 }, 'manager')
  end, nil, 'the minimum aspect cannot fit the controls')
  expect.raises(function()
    managerConfig.schema.parse({ width = 5, height = 2.6624, pixels = 800 }, 'manager')
  end, nil, 'a canvas below the body-row boundary is rejected')
  for _, config in
    {
      { width = 5, height = 2.6625, pixels = 800, visible = true },
      { width = 0.1, height = 5, pixels = 2400, visible = true },
    }
  do
    local parsed = managerConfig.schema.parse(config, 'manager')
    local running, _, all, state = boot(parsed)
    local selected
    for _, entry in running.service:entries() do
      if entry.id == 'desktop/manager' then
        selected = entry
      end
    end
    state.view.selection = { kind = 'node', id = selected.instanceId }
    controller.update(state)
    for _, label in { 'Configure', 'Catalog' } do
      for _, button in state.buttons do
        expect.truthy(button.y + button.height <= state.height, 'every toolbar button is reachable')
        if button.label == label then
          controller.press(state, { x = button.x + 1, y = button.y + 1 })
        end
      end
      expect.truthy(#state.rows > 0, label .. ' has a body row')
      expect.truthy(state.rows[1].y + state.rows[1].height <= state.height - 64, 'a body row fits above the footer')
    end
    expect.equal(#all(), 1, 'valid dimensions activate')
    running.runtime:close()
  end
end)

test('a manager draw failure restores the caller transform before the next frame handler', function()
  local seen
  local observer = plugin.define {
    name = 'draw-observer',
    requires = { frame = frameContract.capability },
    init = function(context)
      context:require(frameContract.capability):onDraw(context, {
        phase = 'overlay',
        order = 1001,
        run = function(pass)
          seen = vector.pack(pass.current:getPosition())
        end,
      })
    end,
  }
  local running, fake = boot({ visible = true }, { { id = 'draw-observer', definition = observer } })
  local pass = fake.events.pass
  pass.current = lovr.math.newMat4():translate(3, 4, 5)
  local expected = vector.pack(pass.current:getPosition())
  local stack = {}
  pass.push = function(self, kind)
    if kind == 'transform' then
      stack[#stack + 1] = lovr.math.newMat4(self.current)
    end
  end
  pass.pop = function(self, kind)
    if kind == 'transform' then
      self.current:set(table.remove(stack))
    end
  end
  pass.transform = function(self, pose)
    self.current:mul(pose)
  end
  pass.translate = function(self, ...)
    self.current:translate(...)
  end
  pass.scale = function(self, ...)
    self.current:scale(...)
  end
  lovr.graphics.getDefaultFont = function()
    error('injected manager draw failure', 0)
  end
  lovr.draw(pass)
  local reports = fake.events.reported
  running.runtime:close()
  expect.equal(seen, expected, 'the following handler receives the original transform')
  expect.equal(#stack, 0, 'the caller transform is unwound')
  expect.equal(#reports, 1, 'the frame boundary reports the draw error')
  expect.truthy(reports[1].message:find('injected manager draw failure', 1, true), 'the original failure is retained')
end)

return test
