local testing = require '@testing'
local expect = testing.expect
local adapter = require '@lunette-plugin/adapter'
local drops = require '@lunette-contracts/drops'
local panels = require '@lunette-contracts/panels'
local rules = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'
local poseMemory = require '@lunette-plugins/desktop/adoption/pose-memory'

local test = testing.suite()

local function pose(x)
  return vocabulary.encodePose(lovr.math.newMat4():translate(x, 0, 0))
end

test('a dropped window keeps its pose, and the kept pose wins over a persisted one', function()
  local fake = testing.native()
  local session = testing.start { 'theme', 'panels', 'drops', 'rules' }
  local env = {}
  session:use(adapter.define {
    name = 'pose-memory-test',
    requires = { panels.capability, drops.capability, rules.capability },
    init = function(context)
      env.owner = context
      env.panels = context:require(panels.capability)
      env.drops = context:require(drops.capability)
      env.rules = context:require(rules.capability)
    end,
  })
  env.rules:addSource(env.owner, {
    name = 'persistence',
    precedence = vocabulary.PRECEDENCE.persisted,
    resolve = function()
      return { pose = pose(2) }
    end,
  })
  session:use(poseMemory)
  local window = fake.newWindow(1)
  expect.equal(env.rules:resolve(window).pose, pose(2), 'a window that kept no pose takes the persisted one')
  local panel = env.panels:fromWindow(env.owner, window, { height = 1 })
  panel:setPose(lovr.math.newMat4():translate(3, 0, 0))
  env.drops:emit(env.owner, { surface = panel, pointer = {} })
  expect.equal(window.properties[vocabulary.POSE_PROPERTY], pose(3), 'the drop writes the pose to the window')
  expect.equal(env.rules:resolve(window).pose, pose(3), 'the kept pose wins over the persisted one')
  session:close()
end)

return test
