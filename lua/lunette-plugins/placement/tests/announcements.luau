local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local rulesContract = require '@lunette-contracts/rules'
local placementContract = require '@lunette-contracts/placement'

local test = testing.suite()

local function consumer(session, name)
  local found = {}
  session:use(plugin.define {
    name = name,
    requires = {
      panels = panelsContract.capability,
      rules = rulesContract.capability,
      placement = placementContract.capability,
    },
    init = function(context)
      found.owner = context
      found.panels = context:require(panelsContract.capability)
      found.rules = context:require(rulesContract.capability)
      found.placement = context:require(placementContract.capability)
    end,
  })
  return found
end

local function start()
  local env = { native = testing.native(), announced = {} }
  env.session = testing.start { 'theme', 'panels', 'tags', 'rules', 'placement' }
  env.listener = consumer(env.session, 'placement-listener')
  env.placer = consumer(env.session, 'placement-placer')
  env.listener.rules:addSource(env.listener.owner, {
    name = 'fixture',
    precedence = 100,
    resolve = function(window)
      if window.appId == 'firefox' then
        return { pose = lovr.math.newMat4():translate(1, 1.5, -2) }
      end
      return {}
    end,
  })
  env.listener.placement:onPlaced(env.listener.owner, {
    run = function(placed)
      env.announced[#env.announced + 1] = placed
    end,
  })
  return env
end

test('onPlaced hears each placement with its properties, whoever made it, and placed lists them in order', function()
  local env = start()
  local terminal, browser = env.native.newWindow(40), env.native.newWindow(41, 'firefox')
  local first = env.listener.placement:place(env.listener.owner, { window = terminal })
  local second = env.placer.placement:place(env.placer.owner, { window = browser })
  expect.equal(#env.announced, 2, 'the announcements')
  expect.equal(env.announced[1].panel, first, 'the first announced panel')
  expect.equal(env.announced[2].panel, second, "the other consumer's placement is announced")
  expect.equal(env.announced[1].properties.pose, nil, 'the rules gave the terminal no pose')
  expect.truthy(env.announced[2].properties.pose, 'the rules gave firefox a pose')
  local x, _, z = second.pose:getPosition()
  expect.near(x, 1, 1e-5, 'the firefox panel takes the x of its pose')
  expect.near(z, -2, 1e-5, 'the firefox panel takes the z of its pose')
  local placed = env.listener.placement:placed()
  expect.equal(#placed, 2, 'the live placements')
  expect.equal(placed[1].panel, first, 'the first placement lists first')
  expect.equal(placed[2].panel, second, 'the second placement lists second')
  env.session:close()
end)

return test
