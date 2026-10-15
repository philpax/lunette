local testing = require '@testing'
local render = require '@testing/render'
local laser = require '../'
local contract = require '@lunette-contracts/laser'
local expect = testing.expect
local test = testing.suite()

type Window = testing.Window
type Panel = {
  dead: boolean,
  kind: 'window',
  source: Window,
  width: number,
  height: number,
  pose: Mat4,
  raycast: () -> (number, number, number),
}
type Drag = {
  dead: boolean,
  width: number,
  height: number,
  x: number,
  y: number,
  opaque: boolean,
  crop: { number },
  texture: (string | false)?,
  getTexture: ((Drag) -> string | false | nil)?,
  getSourceCrop: ((Drag) -> ...number)?,
}
type DragFields = { opaque: boolean?, crop: { number }?, texture: (string | false)?, width: number?, height: number? }
type Seat = testing.Seat & { drag: Drag? }
type Fixture = { native: testing.Native, target: laser.Beam, panel: Panel, seat: Seat }

local ICON = 'icon texture'
local ORIGIN = vector.pack(0, 1, 0)

-- A left laser aiming straight ahead from ORIGIN, and a window panel two metres wide for a thousand pixels, three
-- metres ahead, so a surface pixel is two millimetres.
local function fixture(): Fixture
  local native = testing.native()
  local session = testing.start {
    'theme',
    'drops',
    'focus',
    'interaction',
    { id = 'laser', definition = laser.definition },
  }
  local observer = session:observe(contract.capability)
  local target = observer.service:attach(observer.context, {
    readInput = function(hand: contract.Hand): contract.Input?
      if hand ~= 'left' then
        return nil
      end
      return {
        pose = lovr.math.newMat4(),
        origin = ORIGIN,
        direction = vector.pack(0, 0, -1),
        buttons = {},
        grip = false,
        dt = 1 / 60,
      }
    end,
  })[1]
  local window = native.newWindow(1)
  local panel = {
    dead = false,
    kind = 'window',
    source = window,
    width = 2,
    height = 1,
    pose = lovr.math.newMat4():translate(0, 1, -3),
    raycast = function(): (number, number, number)
      return 500, 250, 3
    end,
  }
  return { native = native, target = target, panel = panel, seat = native.events.seats[1] }
end

local function drag(fields: DragFields?): Drag
  local made: Drag = { dead = false, width = 40, height = 20, x = -10, y = -5, opaque = false, crop = { 0, 0, 1, 1 } }
  made.texture = ICON
  for key, value in fields or {} do
    made[key] = value
  end
  function made.getTexture(self: Drag): string | false | nil
    return self.texture
  end
  function made.getSourceCrop(self: Drag): ...number
    return table.unpack(self.crop)
  end
  return made
end

local function drawn(env: Fixture): ({ render.Call }, render.Recorder)
  local recorder = render.new()
  env.target:draw(recorder.pass)
  local found: { render.Call } = {}
  for _, call in recorder.calls do
    if call[1] == 'draw' and call.state.setMaterial and call.state.setMaterial[1] == ICON then
      found[#found + 1] = call
    end
  end
  return found, recorder
end

local function bounds(call: render.Call): (vector, vector)
  local low = vector.pack(math.huge, math.huge, math.huge)
  local high = vector.pack(-math.huge, -math.huge, -math.huge)
  for _, point in call.points do
    low = vector.min(low, point)
    high = vector.max(high, point)
  end
  return low, high
end

test('a drag icon is drawn at the hit point, facing the hand, at the hovered panel scale', function()
  local env = fixture()
  env.seat.drag = drag()
  env.target:update { env.panel }
  local calls, recorder = drawn(env)
  expect.equal(#calls, 1, 'one icon is drawn')
  local low, high = bounds(calls[1])
  -- The corner sits ten pixels left of and five above the pointer, at two millimetres a pixel.
  expect.near(low.x, -0.02, 1e-6, 'left edge')
  expect.near(high.x, 0.06, 1e-6, 'right edge')
  expect.near(high.y, 1.01, 1e-6, 'top edge')
  expect.near(low.y, 0.97, 1e-6, 'bottom edge')
  expect.near(low.z, -3, 1e-6, 'the icon lies at the hit point')
  expect.near(high.z, -3, 1e-6, 'the icon faces the hand')
  local state = calls[1].state
  expect.equal(state.setDepthTest[1], nil, 'the icon is an overlay, as the beam is')
  expect.equal(state.setBlendMode[2], 'premultiplied', 'client pixels are premultiplied')
  expect.truthy(state.setShader[1] and state.setShader[1].fragment:find('pixel.a', 1, true), 'alpha conversion')
  recorder:assertRestored()
end)

test('an opaque icon uses the opaque conversion', function()
  local env = fixture()
  env.seat.drag = drag { opaque = true }
  env.target:update { env.panel }
  local calls = drawn(env)
  expect.equal(calls[1].state.setShader[1].fragment:find('pixel.a', 1, true), nil)
end)

test('a cropped icon samples only its crop', function()
  local env = fixture()
  env.seat.drag = drag { crop = { 0.25, 0, 0.5, 1 } }
  env.target:update { env.panel }
  local calls = drawn(env)
  local mesh = calls[1][2]
  for _, vertex in mesh.vertices do
    expect.truthy(vertex[7] >= 0.25 - 1e-9 and vertex[7] <= 0.75 + 1e-9, 'u stays within the crop')
  end
end)

test('nothing is drawn without a drag, or for a drag without an icon', function()
  local env = fixture()
  env.target:update { env.panel }
  expect.equal(#drawn(env), 0, 'no drag')
  env.seat.drag = drag { texture = false, width = 0, height = 0 }
  expect.equal(#drawn(env), 0, 'no icon')
end)

test('off every panel, the icon keeps the last scale at the end of the beam', function()
  local env = fixture()
  env.seat.drag = drag()
  env.target:update { env.panel }
  env.target:update {}
  local calls = drawn(env)
  local low, high = bounds(calls[1])
  expect.near(high.x - low.x, 0.08, 1e-6, 'forty pixels at the remembered scale')
  expect.truthy(low.z < -3.0 or low.z > -3.0, 'the beam end is no longer the panel')
end)

test('the icon mesh is replaced when the crop changes and released with the laser', function()
  local env = fixture()
  env.seat.drag = drag()
  env.target:update { env.panel }
  local first = drawn(env)[1][2]
  env.seat.drag.crop = { 0, 0, 0.5, 0.5 }
  local second = drawn(env)[1][2]
  expect.truthy(first ~= second, 'a new crop builds a new mesh')
  expect.truthy(first.released, 'the old mesh is released')
  expect.equal(drawn(env)[1][2], second, 'an unchanged crop reuses the mesh')
  env.target:destroy()
  expect.truthy(second.released, 'destroying the laser releases the mesh')
end)

return test
