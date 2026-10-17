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

-- A panel with one button, ahead of the fake head, and the mouse pointer, which drives a headset session only when its
-- configuration asks.
local function boot(config: { [string]: any }?): Scene
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
    plugins = { { definition = mousePointer.definition, config = config or { headset = true } } },
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

test('by default a headset session takes no mouse input, and makes no seat or cursor', function()
  local scene = boot {}
  local dx, dy = movementTo(scene, 'go')
  lovr.mousemoved(400, 300, dx, dy)
  lovr.mousepressed(400, 300, 1)
  lovr.mousereleased(400, 300, 1)
  frame(scene)
  frame(scene)
  expect.equal(mouseSeats(scene), 0, 'no mouse seat')
  expect.equal(#spheres(scene), 0, 'no cursor')
  expect.equal(scene.activations, 0, 'the click reaches nothing')
  scene.state.fixture:close()
end)

test('in a headset session the cursor withdraws after a while without mouse input, and returns with input', function()
  local scene = boot()
  local dx, dy = movementTo(scene, 'go')
  lovr.mousemoved(400, 300, dx, dy)
  frame(scene)
  expect.equal(#spheres(scene), 1, 'the cursor shows after a move')
  local button = assert(scene.state.panel:find 'go')
  expect.truthy(button.state.hovered, 'and hovers the button ahead')
  scene.state.fixture:step(2)
  frame(scene)
  expect.equal(#spheres(scene), 1, 'the cursor stays during a short pause')
  scene.state.fixture:step(2)
  frame(scene)
  expect.equal(#spheres(scene), 0, 'the cursor withdraws after the idle timeout')
  expect.falsy(button.state.hovered, 'and stops hovering what the head faces')
  lovr.mousemoved(400, 300, 0, 0)
  frame(scene)
  expect.equal(#spheres(scene), 1, 'the next mouse input brings it back')
  scene.state.fixture:close()
end)

-- The window pixel where the simulator shows a node, for a head that faces -Z without turning.
local function windowPoint(scene: Scene, path: string): (number, number)
  local node = assert(scene.state.panel:find(path), `no node at {path}`)
  local offset = vector.pack(node:pose():getPosition()) - headPosition(scene)
  local window = scene.state.fixture.native.events.window
  local left, right, up, down =
    math.tan(window.view[1]), math.tan(window.view[2]), math.tan(window.view[3]), math.tan(window.view[4])
  local tx, ty = offset.x / -offset.z, offset.y / -offset.z
  return (tx + left) / (left + right) * window.width, (up - ty) / (up + down) * window.height
end

test('in the simulator the ray follows the window cursor, and a click there activates the button', function()
  local scene = boot()
  local events = scene.state.fixture.native.events
  events.headsetActive = false
  local x, y = windowPoint(scene, 'go')
  -- The movement is far from the button, so only the absolute position can aim the ray at it.
  lovr.mousemoved(x, y, -500, 400)
  frame(scene)
  local node = assert(scene.state.panel:find 'go')
  local nx, ny = node:pose():getPosition()
  local cursors = spheres(scene)
  expect.equal(#cursors, 1, 'one cursor')
  expect.near(cursors[1][2] :: number, nx, 0.002, 'the cursor sits on the button horizontally')
  expect.near(cursors[1][3] :: number, ny, 0.002, 'the cursor sits on the button vertically')
  lovr.mousepressed(x, y, 1)
  frame(scene)
  lovr.mousereleased(x, y, 1)
  frame(scene)
  expect.equal(scene.activations, 1, 'the click activates the button')

  -- While the window holds the mouse in relative mode, a movement keeps the aim.
  events.window.mouseMode = 'relative'
  lovr.mousemoved(0, 0, 300, 300)
  frame(scene)
  local held = spheres(scene)
  expect.near(held[1][2] :: number, nx, 0.002, 'the aim stays on the button')
  scene.state.fixture:close()
end)

return test
