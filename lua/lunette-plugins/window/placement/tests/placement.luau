local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local rulesContract = require '@lunette-contracts/rules'
local placementContract = require '@lunette-contracts/placement'
local vocabulary = require '@lunette-contracts/vocabulary'

local test = testing.suite()

type Environment = {
  native: testing.Native,
  session: testing.Session?,
  consumer: adapter.Instance<{}>?,
  owner: plugin.Context?,
  panels: panelsContract.Service?,
  tags: tagsContract.Service?,
  rules: rulesContract.Service?,
  placement: placementContract.Service?,
  primary: tagsContract.Tag?,
  window: testing.Window?,
}

local function start(): Environment
  local env: Environment = { native = testing.native() }
  env.session = testing.start { 'theme', 'panels', 'tags', 'rules', 'placement' }
  env.consumer = env.session:use(adapter.define {
    name = 'placement-test',
    requires = {
      panelsContract.capability,
      tagsContract.capability,
      rulesContract.capability,
      placementContract.capability,
    },
    init = function(context: plugin.Context)
      env.owner = context
      env.panels = context:require(panelsContract.capability)
      env.tags = context:require(tagsContract.capability)
      env.rules = context:require(rulesContract.capability)
      env.placement = context:require(placementContract.capability)
    end,
  })
  env.primary = env.tags:hold(env.owner, { name = 'primary' })
  env.primary:setSelected(env.owner, true)
  env.window = env.native.newWindow(1)
  env.rules:addSource(env.owner, {
    name = 'fixture',
    precedence = 100,
    resolve = function(): rulesContract.Properties
      return { width = 3, tags = { 'primary', 'implicit' } }
    end,
  })
  return env
end

local function place(env: Environment): (panelsContract.Panel, placementContract.Properties, plugin.Effect)
  local placed, effect = env.placement:place(env.owner, { window = env.window, defaults = { width = 5, height = 1 } })
  return placed.panel, placed.properties, effect
end

test('a placed window takes its resolved properties over the defaults, joins their tags, and is announced', function()
  local env = start()
  local announced: { placementContract.Placement } = {}
  env.placement:onPlaced(env.owner, {
    run = function(placed: placementContract.Placement)
      announced[#announced + 1] = placed
    end,
  })
  local panel, resolved = place(env)
  expect.equal(resolved.width, 3, 'a resolved property wins over a default')
  expect.equal(resolved.height, 1, 'a default fills what the rules leave unset')
  expect.equal(panel.width, 3, 'the panel width')
  expect.truthy(env.primary:has(panel), 'the placement joins an existing tag')
  local implicit = env.tags:find 'implicit'
  expect.truthy(implicit and implicit:has(panel), 'a tag nothing declared is made and joined')
  expect.equal(announced[1].panel, panel, 'the announced panel')
  expect.equal(announced[1].properties.width, 3, 'the announced properties')
  expect.equal(env.placement:placed()[1].panel, panel, 'the live placements')
  env.session:close()
end)

test('a placement that fails part way releases its panel and the tags it made', function()
  local env = start()
  -- A log failure after panel creation exercises acquisition rollback.
  lovr.log = function(): never
    error 'injected report failure'
  end
  expect.raises(function()
    place(env)
  end, 'injected report failure', 'the placement')
  lovr.log = function() end
  expect.equal(#env.panels:all(), 0, 'the panels after the rollback')
  expect.equal(env.tags:find 'implicit', nil, 'the tag made for the placement')
  env.session:close()
end)

test('a placement ends with its window, with its effect, and with its owner', function()
  local env = start()
  local panel, _, placement = place(env)
  env.window.dead = true
  env.panels:update()
  expect.truthy(panel.dead, 'a panel whose window died')
  expect.equal(#env.placement:placed(), 0, 'the live placements after the window dies')
  expect.equal(env.tags:find 'implicit', nil, 'the tag only the placement held')
  expect.equal(#env.primary:panels(), 0, 'the membership of a tag its owner made')
  placement:dispose()

  env.window.dead = false
  local again, _, replaced = place(env)
  replaced:dispose()
  expect.truthy(again.dead, 'disposing a placement removes its panel')

  local last = place(env)
  env.consumer:disable()
  expect.truthy(last.dead, "an unloading owner's placement")
  expect.equal(#env.panels:all(), 0, 'the panels after the owner unloads')
  env.session:close()
end)

test('resolved lock properties initialize panels and false overrides a locked default', function()
  local env = start()
  env.rules:addSource(env.owner, {
    name = 'locks',
    precedence = 200,
    resolve = function(): rulesContract.Properties
      return { locked = true }
    end,
  })
  local panel, resolved = place(env)
  expect.equal(resolved.locked, true, 'rules resolve the lock property')
  expect.truthy(panel.locked, 'placement forwards locks to panel options')
  local unlocked = env.placement:place(env.owner, {
    window = env.native.newWindow(2),
    properties = { locked = false },
    defaults = { locked = true },
  })
  expect.falsy(unlocked.panel.locked, 'explicit false overrides the default')
  env.session:close()
end)

test('a rule transform lock initializes a panel and placement still poses it', function()
  local env = start()
  local pose = lovr.math.newMat4():translate(2, 1.5, -3)
  env.rules:addSource(env.owner, {
    name = 'fixture-lock',
    precedence = 50,
    resolve = function(): rulesContract.Properties
      return { pose = vocabulary.encodePose(pose), transformLocked = true }
    end,
  })
  local panel = place(env)
  expect.truthy(panel.transformLocked, 'the rule transform lock initializes the panel')
  expect.truthy(panel.transformLockedExplicit, 'the creator rule is explicit')
  expect.near(panel.pose:getPosition(), 2, 1e-5, 'placement still poses the locked panel')
  env.session:close()
end)

test('a rule curve axis initializes a panel and placement still poses it', function()
  local env = start()
  local pose = lovr.math.newMat4():translate(1, 1.5, -2)
  env.rules:addSource(env.owner, {
    name = 'fixture-curve',
    precedence = 50,
    resolve = function(): rulesContract.Properties
      return { pose = vocabulary.encodePose(pose), curve = 0.5, curveAxis = math.pi / 4 }
    end,
  })
  local panel = place(env)
  expect.near(panel.curve, 0.5, 1e-9, 'the rule curve initializes the panel')
  expect.near(panel.curveAxis, math.pi / 4, 1e-9, 'the rule axis initializes the panel')
  expect.truthy(panel.curveExplicit, 'the rule curve is explicit')
  expect.truthy(panel.curveAxisExplicit, 'the rule axis is explicit')
  expect.near(panel.pose:getPosition(), 1, 1e-5, 'placement still poses the panel')
  env.session:close()
end)

return test
