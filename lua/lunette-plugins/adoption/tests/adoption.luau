local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local adoptionContract = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local placementContract = require '@lunette-contracts/placement'
local rulesContract = require '@lunette-contracts/rules'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

local function pose(x)
  return vocabulary.encodePose(lovr.math.newMat4():translate(x, 0, 0))
end

test('start adopts each accepted window once with its resolved properties, and releases them when disposed', function()
  local fake = testing.native()
  local session = testing.start { 'theme', 'panels', 'tags', 'rules', 'placement', 'adoption' }
  local env = {}
  session:use(adapter.define {
    name = 'adoption-test',
    requires = {
      panelsContract.capability,
      placementContract.capability,
      rulesContract.capability,
      adoptionContract.capability,
    },
    init = function(context)
      env.owner = context
      env.panels = context:require(panelsContract.capability)
      env.placement = context:require(placementContract.capability)
      env.rules = context:require(rulesContract.capability)
      env.adoption = context:require(adoptionContract.capability)
    end,
  })
  env.rules:addSource(env.owner, {
    name = 'persistence',
    precedence = vocabulary.PRECEDENCE.persisted,
    resolve = function(target)
      return if target.appId == 'fixture.declined' then { adopt = false } else { pose = pose(2) }
    end,
  })
  env.adoption:install(env.owner)
  local saved, ordinary = fake.newWindow(1), fake.newWindow(2)
  local refused, declined = fake.newWindow(3, 'fixture.refused'), fake.newWindow(4, 'fixture.declined')
  saved.properties[vocabulary.POSE_PROPERTY] = pose(3)
  fake.events.windows = { saved, ordinary, refused, declined }
  local started = env.adoption:start(env.owner, {
    filter = function(target)
      return target.appId ~= 'fixture.refused'
    end,
  })
  local placed = env.placement:placed()
  expect.equal(#placed, 2, 'the windows adopted')
  expect.equal(placed[1].properties.pose, pose(3), 'the pose the window kept, above the persisted one')
  expect.equal(placed[2].properties.pose, pose(2), 'the persisted pose of a window that kept none')

  fake.emit('onWindowOpened', { window = saved })
  expect.equal(#env.panels:all(), 2, 'an adopted window opening again')
  fake.emit('onWindowOpened', { window = fake.newWindow(5) })
  expect.equal(#env.panels:all(), 3, 'an arriving window')
  started:dispose()
  expect.equal(#env.panels:all(), 0, 'disposing the start releases its panels')
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions after the dispose')
  session:close()
end)

test('adoption places through a substitute placement provider, and ends with its caller', function()
  local native = testing.native()
  local placements = {}
  local substitute = adapter.define {
    name = 'substitute-placement',
    requires = { panelsContract.capability },
    provides = { placementContract.capability },
    init = function(context, _, publish)
      local panels = context:require(panelsContract.capability)
      publish:provide(placementContract.capability, {
        place = function(_, owner, request)
          local panel
          local effect = context:acquire(owner, function()
            panel = panels:fromWindow(context, request.window)
            placements[#placements + 1] = panel
            return function()
              table.remove(placements, table.find(placements, panel))
              panel:destroy(context)
            end
          end)
          return panel, {}, effect
        end,
      })
    end,
  }
  local session = testing.start {
    'theme',
    'panels',
    'rules',
    { id = 'placement', definition = substitute },
    'adoption',
  }
  native.events.windows = { native.newWindow(41) }
  local caller = session:use(adapter.define {
    name = 'substitute-placement-test',
    requires = { adoptionContract.capability },
    init = function(context)
      local adoption = context:require(adoptionContract.capability)
      adoption:install(context)
      adoption:start(context)
    end,
  })
  expect.equal(#placements, 1, 'the placements made through the substitute')
  local adopted = placements[1]
  caller:disable()
  expect.truthy(adopted.dead, "the panel after the caller's adoption ends")
  expect.equal(#placements, 0, 'the placements after the caller unloads')
  session:close()
end)

return test
