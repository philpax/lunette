local testing = require '@testing'
local surfaces = require '@lunette-contracts/surfaces'
local definition = require('../').definition
local memory = require '../private/memory'
local expect = testing.expect
local test = testing.suite()

-- A keyed surface that is neither a toolkit panel nor the keyboard, which records what is done to it.
local function keyed(key: string?): any
  local surface = {
    dead = false,
    placementKey = key,
    pose = lovr.math.newMat4():translate(0, 1.5, -1),
    width = 0.4,
    height = 0.3,
    sized = 0,
    raycast = function(): ()
      return nil
    end,
  }
  surface.setPose = function(self: any, pose: Mat4): ()
    self.pose:set(pose)
  end
  surface.setSize = function(self: any, width: number?): ()
    self.width = width
    self.sized += 1
  end
  return surface
end

-- Starts placement memory with a saved store and offers the surfaces to it.
local function start(placed: { [string]: any }, offered: { any }): testing.Session
  local session = testing.boot { 'frame', 'surfaces', 'drops' }
  session:use(definition, { placed = placed })
  local observed = session:observe(surfaces.capability)
  observed.service:offer(observed.context, {
    name = 'test',
    list = function(): { any }
      return offered
    end,
  })
  return session
end

test('a capture and its application return a surface to its pose and width', function()
  local source = keyed 'source'
  source.pose:set(lovr.math.mat4():translate(0.3, 1.2, -0.7):rotate(0.6, 0, 1, 0))
  source.width = 0.55
  local placement = assert(memory.capture(source))
  local target = keyed 'target'
  memory.apply(target, placement)
  for index, value in { source.pose:unpack(true) } do
    expect.near(({ target.pose:unpack(true) })[index], value, 1e-6, `pose component {index}`)
  end
  expect.near(target.width, 0.55, 1e-9, 'the width')
end)

test('a surface without a way to resize saves no width, and one without a pose saves nothing', function()
  local fixed = keyed 'fixed'
  fixed.setSize = nil
  expect.equal(assert(memory.capture(fixed)).width, nil)
  local unposed = keyed 'unposed'
  unposed.pose = nil
  expect.equal(memory.capture(unposed), nil)
end)

test('an offered keyed surface returns to its saved placement once, and an unkeyed one is left alone', function()
  local remembered, other, unkeyed = keyed 'remembered', keyed 'other', keyed(nil)
  local session = start({
    remembered = { position = vector.create(0.5, 1.2, -1), rotation = { 0, 0, 1, 0 }, width = 0.6 },
    unkeyed = { position = vector.create(9, 9, 9), rotation = { 0, 0, 1, 0 } },
  }, { remembered, other, unkeyed })
  session:update()
  expect.near(vector.pack(remembered.pose:getPosition()).x, 0.5, 1e-6, 'the saved surface returns')
  expect.near(remembered.width, 0.6, 1e-9, 'at its saved width')
  expect.near(vector.pack(other.pose:getPosition()).x, 0, 1e-6, 'a key with no placement stays at its pose')
  expect.near(vector.pack(unkeyed.pose:getPosition()).x, 0, 1e-6, 'an unkeyed surface is not placed')
  remembered.pose:set(lovr.math.mat4():translate(2, 1, -1))
  session:update()
  expect.near(vector.pack(remembered.pose:getPosition()).x, 2, 1e-6, 'a restored surface is not placed again')
  expect.equal(remembered.sized, 1, 'or sized again')
  session:close()
end)

test('a surface that gains its key after it is first offered is not moved to a saved placement', function()
  local late = keyed(nil)
  local session = start({ late = { position = vector.create(0.7, 1.2, -1), rotation = { 0, 0, 1, 0 } } }, { late })
  session:update()
  late.placementKey = 'late'
  session:update()
  expect.near(vector.pack(late.pose:getPosition()).x, 0, 1e-6, 'a surface keyed as it is torn off stays in hand')
  session:close()
end)

return test
