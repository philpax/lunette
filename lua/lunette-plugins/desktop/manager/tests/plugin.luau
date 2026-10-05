local testing = require '@testing'
local plugin = require '@lunette-plugin'
local management = require '@lunette-plugin/management'
local frame = require '@lunette-plugins/frame'
local surfaces = require '@lunette-plugins/surfaces'
local surfaceContract = require '@lunette-contracts/surfaces'
local manager = require '@lunette-plugins/desktop/manager'
local controller = require '@lunette-plugins/desktop/manager/controller'
local managerConfig = require '@lunette-plugins/desktop/manager/config'
local frameContract = require '@lunette-contracts/frame'
local interactionContract = require '@lunette-contracts/interaction'
local interaction = require '@lunette-plugins/interaction'
local drops = require '@lunette-plugins/drops'
local focus = require '@lunette-plugins/focus'
local expect = testing.expect
local test = testing.suite()

local function boot(config, additions, protected)
  local fake = testing.native()
  local font = {
    getHeight = function()
      return 1
    end,
    getLineSpacing = function()
      return 1
    end,
    getWidth = function(_, text)
      return #text * 0.5
    end,
    getLines = function(_, text)
      local result = {}
      for line in (text .. '\n'):gmatch '(.-)\n' do
        result[#result + 1] = line
      end
      return result
    end,
  }
  lovr.graphics.getDefaultFont = function()
    return font
  end
  for _, name in
    {
      'push',
      'pop',
      'transform',
      'translate',
      'scale',
      'setShader',
      'setMaterial',
      'setFont',
      'setCullMode',
      'setDepthTest',
      'setDepthWrite',
    }
  do
    fake.events.pass[name] = function(_, ...)
      fake.events.draw[#fake.events.draw + 1] = { name, ... }
    end
  end
  local surfaceService
  local observed = plugin.define {
    name = 'surface-observer',
    requires = { surfaces = surfaceContract.capability },
    init = function(context)
      surfaceService = context:require(surfaceContract.capability)
    end,
  }
  frame.install { start = function() end, stop = function() end }
  local entries = {
    { id = 'frame', definition = frame.definition },
    { id = 'surfaces', definition = surfaces.definition },
    { id = 'desktop/manager', definition = manager, config = config or {} },
    { id = 'observer', definition = observed },
  }
  for _, entry in additions or {} do
    entries[#entries + 1] = entry
  end
  local state
  local new = controller.new
  controller.new = function(...)
    state = new(...)
    return state
  end
  local ok, running = pcall(management.start, entries, { protected = protected or { 'desktop/manager' } })
  controller.new = new
  if not ok then
    error(running, 0)
  end
  return running, fake, function()
    return surfaceService:all()
  end, state
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
  local pointer = {}
  offered:onHover(x, y, pointer)
  offered:onPress(x, y, pointer)
  offered:onRelease(pointer)
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
  local first, second = {}, {}
  local camera = state.view.camera
  offered:onPress(1, 1, first)
  offered:onHover(100, 100, second)
  offered:onPress(100, 100, second)
  offered:onLeave(second)
  offered:onRelease(second)
  local afterOther, dragging = state.view.camera, state.view.dragging
  offered:onHover(21, 31, first)
  local moved = state.view.camera
  offered:onRelease(first)
  local ended = state.view.dragging
  local released = state.view.camera
  offered:onHover(80, 80, second)
  local hovered = state.view.camera
  offered:onPress(1, 1, second)
  offered:onHover(11, 11, second)
  offered:onRelease(second)
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
  local pointer = {}
  offered:onPress(1, 1, pointer)
  lovr.keypressed('f10', 0, false)
  local hiddenDrag = state.view.dragging
  lovr.keypressed('f10', 0, false)
  local camera = state.view.camera
  offered:onHover(30, 30, pointer)
  local hovered = state.view.camera
  offered:onPress(1, 1, {})
  local nextDrag = state.view.dragging
  running.runtime:close()
  expect.equal(hiddenDrag, nil, 'hiding cancels the drag')
  expect.equal(hovered.x, camera.x, 'hover cannot resume the hidden press')
  expect.truthy(nextDrag, 'capture is available again')
end)

test('shutdown invalidates retained surface methods and clears the pending gesture', function()
  local running, _, all, state = boot { visible = true }
  local offered = all()[1]
  local pointer = {}
  offered:onHover(1, 1, pointer)
  offered:onPress(1, 1, pointer)
  local position = vector.pack(offered.pose:getPosition())
  local camera = state.view.camera
  running.runtime:close()
  expect.equal(offered.dead, true, 'the public surface is dead')
  expect.equal(state.view.dragging, nil, 'capture is cancelled at shutdown')
  offered:setPose(lovr.math.newMat4():translate(8, 9, 10))
  offered:onHover(20, 30, pointer)
  offered:onPress(20, 30, pointer)
  offered:onLeave(pointer)
  offered:onRelease(pointer)
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
