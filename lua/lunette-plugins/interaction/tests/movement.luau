local testing = require '@testing'
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-plugins/interaction'
local contracts = require '@lunette-contracts/interaction'
local expect = testing.expect
local test = testing.suite()

local function fixture(config)
  testing.native()
  local session = testing.start {
    'focus',
    'drops',
    { id = 'interaction', definition = interaction.define(config or {}) },
  }
  local pointer
  session:use(plugin.define {
    name = 'movement-fixture',
    requires = { interaction = contracts.capability },
    init = function(owner)
      pointer = owner:require(contracts.capability):newPointer(owner)
    end,
  })
  local target = {
    pose = lovr.math.newMat4():translate(0, 1, -2):rotate(0.3, 0, 1, 0),
    width = 1,
    height = 0.6,
    dead = false,
    raycast = function()
      return 0.5, 0.3, 2
    end,
  }
  function target:setPose(pose)
    self.pose:set(pose)
  end
  function target:setSize(width)
    self.height *= width / self.width
    self.width = width
  end
  local function update(pose, grip)
    pointer:update({
      pose = pose,
      origin = vector.pack(pose:getPosition()),
      direction = vector.pack(0, 0, -1),
      buttons = {},
      grip = grip,
      dt = 0.1,
    }, { target })
  end
  return session, pointer, target, update
end

test('default grab follows controller translation and rotation', function()
  for _, axis in { vector.pack(1, 0, 0), vector.pack(0, 0, 1), vector.pack(0, 1, 0) } do
    local session, _, target, update = fixture()
    local hand = lovr.math.newMat4():translate(0, 1, 0)
    local initial = lovr.math.newMat4(target.pose)
    update(hand, false)
    update(hand, true)
    local moved = lovr.math.newMat4():translate(0.2, 1.1, 0):rotate(0.8, axis.x, axis.y, axis.z)
    update(moved, true)
    local expected = lovr.math.newMat4(moved):mul(lovr.math.newMat4(hand):invert()):mul(initial)
    for _, point in { { 0, 0, 0, 1 }, { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 } } do
      local x, y, z = target.pose:mul(table.unpack(point))
      local ex, ey, ez = expected:mul(table.unpack(point))
      expect.near(x, ex, 1e-5)
      expect.near(y, ey, 1e-5)
      expect.near(z, ez, 1e-5)
    end
    update(moved, false)
    session:close()
  end
end)

return test
