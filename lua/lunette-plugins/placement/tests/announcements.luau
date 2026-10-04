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
  env.session = testing.start { 'panels', 'tags', 'rules', 'placement' }
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
  expect.truthy(table.isfrozen(env.announced[2].properties), 'the announced properties are frozen')
  local placed = env.listener.placement:placed()
  expect.equal(#placed, 2, 'the live placements')
  expect.equal(placed[1].panel, first, 'the first placement lists first')
  expect.equal(placed[2].panel, second, 'the second placement lists second')
  env.session:close()
end)

test('a raising listener is reported and does not undo the placement', function()
  local env = start()
  env.listener.placement:onPlaced(env.listener.owner, {
    run = function()
      error 'a raising placement listener'
    end,
  })
  expect.raises(function()
    env.listener.placement:onPlaced(env.listener.owner, { callback = function() end })
  end, 'placement onPlaced: unknown field callback', 'an unknown listener field')
  local panel = env.placer.placement:place(env.placer.owner, { window = env.native.newWindow(40) })
  expect.equal(#env.announced, 1, 'the listener before the raising one')
  local reported = env.native.events.reported
  expect.equal(#reported, 1, 'the reports')
  expect.truthy(reported[1].message:find('a raising placement listener', 1, true), reported[1].message)
  expect.falsy(panel.dead, 'the panel of the placement')
  expect.equal(#env.listener.placement:placed(), 1, 'the live placements')
  env.session:close()
end)

test('a placement ends with its panel', function()
  local env = start()
  local terminal = env.native.newWindow(40)
  env.placer.placement:place(env.placer.owner, { window = terminal })
  env.placer.placement:place(env.placer.owner, { window = env.native.newWindow(41, 'firefox') })
  terminal.dead = true
  env.listener.panels:update()
  local placed = env.listener.placement:placed()
  expect.equal(#placed, 1, 'the live placements after a window dies')
  expect.equal(placed[1].panel.source.appId, 'firefox', 'the placement that remains')
  env.session:close()
end)

return test
