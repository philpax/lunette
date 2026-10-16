local testing = require '@testing'
local uiHost = require '@lunette-contracts/ui-host'
local fixture = require '@testing/ui-host'
local mousePointer = require '@lunette-plugins/input/mouse-pointer'
local expect = testing.expect

local test = testing.suite()

local element = uiHost.element

-- The default sensitivity, in radians per pixel.
local SENSITIVITY = 0.002

type Scene = {
  state: fixture.State,
  log: { string },
  activations: number,
  scrolls: { { number } },
}

-- A panel with one button, ahead of the fake head, and the mouse pointer with its default settings.
local function boot(): Scene
  local scene: Scene = { log = {}, activations = 0, scrolls = {} } :: any
  scene.state = fixture.boot {
    setup = function(service: uiHost.Service, owner: any)
      fixture.registerKinds(service, owner, scene.log)
      service:registerKind(owner, {
        name = 'test/scroll-recorder',
        layout = {
          kind = 'leaf',
          style = function(): any
            return { width = 0.04, height = 0.02 }
          end,
        },
        event = function(_node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
          if event.kind == 'scroll' then
            local scroll = event :: any
            table.insert(scene.scrolls, { scroll.dx, scroll.dy })
          else
            base(_node, event)
          end
        end,
      })
    end,
    plugins = { mousePointer.definition },
  }
  fixture.show(
    scene.state,
    element('test/column', {
      padding = 0.01,
      gap = 0.01,
      element('test/button', {
        key = 'go',
        onActivate = function()
          scene.activations += 1
        end,
        element('test/leaf', { width = 0.04, height = 0.02 }),
      }),
      element('test/scroll-recorder', { key = 'wheel' }),
    })
  )
  return scene
end

local function headPosition(scene: Scene): vector
  return vector.pack(scene.state.fixture.native.events.headPose:getPosition())
end

-- The mouse movement from the centred cursor that points the ray at a node's centre.
local function movementTo(scene: Scene, path: string): (number, number)
  local node = assert(scene.state.panel:find(path), `no node at {path}`)
  local offset = vector.pack(node:pose():getPosition()) - headPosition(scene)
  local yaw = math.atan2(offset.x, -offset.z)
  local pitch = math.asin(offset.y / vector.magnitude(offset))
  return yaw / SENSITIVITY, -pitch / SENSITIVITY
end

local function spheres(scene: Scene): { testing.DrawCall }
  local found: { testing.DrawCall } = {}
  for _, call in ipairs(scene.state.fixture.native.events.draw) do
    if call[1] == 'sphere' then
      found[#found + 1] = call
    end
  end
  return found
end

local function mouseSeats(scene: Scene): number
  local count = 0
  for _, seat in scene.state.fixture.native.events.seats do
    if seat.name == 'mouse' and not seat.dead then
      count += 1
    end
  end
  return count
end

local function frame(scene: Scene): ()
  table.clear(scene.state.fixture.native.events.draw)
  scene.state.fixture:step()
  scene.state.fixture:draw()
end

test('until the mouse moves, the pointer has no seat, hovers nothing, and draws no cursor', function()
  local scene = boot()
  lovr.mousepressed(0, 0, 1)
  frame(scene)
  lovr.mousereleased(0, 0, 1)
  lovr.wheelmoved(0, 1)
  frame(scene)
  expect.equal(mouseSeats(scene), 0, 'no mouse seat')
  expect.equal(#spheres(scene), 0, 'no cursor')
  expect.equal(#scene.log, 0, 'the button sees no event')
  expect.equal(scene.activations, 0, 'no activation')
  scene.state.fixture:close()
end)

test('a mouse move, press, and release activate the button under the cursor', function()
  local scene = boot()
  local dx, dy = movementTo(scene, 'go')
  lovr.mousemoved(400, 300, dx, dy)
  frame(scene)
  expect.equal(mouseSeats(scene), 1, 'the first movement makes the seat')
  local cursors = spheres(scene)
  expect.equal(#cursors, 1, 'one cursor')
  local node = assert(scene.state.panel:find 'go')
  local nx, ny, nz = node:pose():getPosition()
  expect.near(cursors[1][2] :: number, nx, 0.002, 'the cursor sits on the button horizontally')
  expect.near(cursors[1][3] :: number, ny, 0.002, 'the cursor sits on the button vertically')
  expect.near(cursors[1][4] :: number, nz, 0.01, 'the cursor sits at the button depth')

  lovr.mousepressed(400, 300, 1)
  frame(scene)
  lovr.mousereleased(400, 300, 1)
  frame(scene)
  expect.equal(scene.activations, 1, 'one activation')
  local sequence = table.concat(scene.log, ' ')
  expect.truthy(string.find(sequence, 'go:hover-enter go:press go:release go:activate', 1, true), sequence)

  -- A click that starts and ends between two frames still presses and releases.
  lovr.mousepressed(400, 300, 1)
  lovr.mousereleased(400, 300, 1)
  frame(scene)
  frame(scene)
  expect.equal(scene.activations, 2, 'a quick click activates')
  scene.state.fixture:close()
end)

test('the wheel scrolls the node under the cursor by the scroll scale', function()
  local scene = boot()
  local dx, dy = movementTo(scene, 'wheel')
  lovr.mousemoved(400, 300, dx, dy)
  frame(scene)
  lovr.wheelmoved(0, 2)
  frame(scene)
  expect.equal(#scene.scrolls, 1, 'one scroll')
  expect.near(scene.scrolls[1][1], 0, 1e-6, 'no horizontal scroll')
  expect.near(scene.scrolls[1][2], -30, 1e-6, 'two units up scroll thirty pixels up')
  frame(scene)
  expect.equal(#scene.scrolls, 1, 'the wheel scrolls once')
  scene.state.fixture:close()
end)

test('the cursor draws at the configured distance when the ray hits nothing, and stops with head tracking', function()
  local scene = boot()
  lovr.mousemoved(400, 300, -300, 0)
  frame(scene)
  local cursors = spheres(scene)
  expect.equal(#cursors, 1, 'one cursor')
  local head = headPosition(scene)
  local position = vector.pack(cursors[1][2] :: number, cursors[1][3] :: number, cursors[1][4] :: number)
  expect.near(vector.magnitude(position - head), 1.5, 1e-6, 'the cursor is at the default distance')
  expect.truthy(position.x < head.x, 'the cursor turned left')

  scene.state.fixture:tracked('head', false)
  frame(scene)
  expect.equal(#spheres(scene), 0, 'no cursor without head tracking')
  scene.state.fixture:close()
end)

return test
