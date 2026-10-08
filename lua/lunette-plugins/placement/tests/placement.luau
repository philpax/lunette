local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local rulesContract = require '@lunette-contracts/rules'
local placementContract = require '@lunette-contracts/placement'
local layoutsContract = require '@lunette-contracts/layouts'

local test = testing.suite()

local function start()
  local env = { native = testing.native() }
  env.session = testing.start {
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = { rendering = 'layer' } },
    'tags',
    'rules',
    'placement',
    'layouts',
    'layout/arc',
  }
  env.consumer = env.session:use(plugin.define {
    name = 'placement-test',
    requires = {
      panels = panelsContract.capability,
      tags = tagsContract.capability,
      rules = rulesContract.capability,
      placement = placementContract.capability,
      layouts = layoutsContract.capability,
    },
    init = function(context)
      env.owner = context
      env.panels = context:require(panelsContract.capability)
      env.tags = context:require(tagsContract.capability)
      env.rules = context:require(rulesContract.capability)
      env.placement = context:require(placementContract.capability)
      env.layouts = context:require(layoutsContract.capability)
    end,
  })
  env.primary = env.tags:new(env.owner, 'primary', { selected = true })
  env.window = env.native.newWindow(1)
  env.source = env.rules:addSource(env.owner, {
    name = 'fixture',
    precedence = 100,
    resolve = function()
      return { width = 3, tags = { 'primary', 'implicit' } }
    end,
  })
  return env
end

local function place(env, defaults)
  return env.placement:place(env.owner, { window = env.window, defaults = defaults })
end

test('a placed window takes its resolved properties over the defaults and joins the tags they name', function()
  local env = start()
  local panel, resolved = place(env, { width = 5, height = 1, chrome = false })
  expect.equal(resolved.width, 3, 'a resolved property wins over a default')
  expect.equal(resolved.height, 1, 'a default fills what the rules leave unset')
  expect.equal(panel.width, 3, 'the panel width')
  expect.equal(panel.height, 1, 'the panel height')
  expect.truthy(env.primary:has(panel), 'the placement holds a membership of an existing tag')
  local implicit = env.tags:find 'implicit'
  expect.truthy(implicit and implicit:has(panel), 'a tag nothing declared is made and joined')
  expect.equal(#env.tags:panelsOf { env.primary, implicit }, 1, 'the panel is answered once across its tags')
  expect.raises(function()
    panel:destroy(env.owner)
  end, nil, 'a placed panel belongs to the placement provider')
  env.layouts:apply { name = 'arc', panels = env.tags:panelsOf(env.primary) }
  local x, y, z = panel.pose:getPosition()
  expect.near(x, 0, 1e-5, 'the arc centres a lone panel')
  expect.near(y, 1.5, 1e-5, 'the arc height')
  expect.near(z, -1.6, 1e-5, 'the arc radius')
  env.session:close()
end)

test('a stranger without the policy capabilities cannot place a window', function()
  local env = start()
  local before = #env.panels:all()
  env.session:use(plugin.define {
    name = 'stranger',
    init = function(context)
      expect.raises(function()
        env.placement:place(context, { window = env.window })
      end, nil, 'a placement for a context that does not require placement')
    end,
  })
  expect.equal(#env.panels:all(), before, 'the panels after the refusal')
  env.session:close()
end)

test('a placement that fails part way releases its panel, tags, and layer claim', function()
  local env = start()
  env.source:dispose()
  local before = #env.panels:all()
  -- A log failure after panel creation exercises acquisition rollback.
  lovr.log = function()
    error 'injected report failure'
  end
  expect.raises(function()
    place(env, { tags = { 'rollback' } })
  end, 'injected report failure', 'the placement')
  lovr.log = function() end
  expect.equal(#env.panels:all(), before, 'the panels after the rollback')
  expect.equal(env.tags:find 'rollback', nil, 'the tag made for the placement')
  local claims = env.native.events.claims
  expect.truthy(#claims > 0 and claims[#claims].dead, 'the layer claim of the rolled-back panel')
  env.session:close()
end)

test('a placement ends with its window, with its effect, and with its owner', function()
  local env = start()
  local panel, _, placement = place(env, { height = 1, chrome = false })
  env.window.dead = true
  env.panels:update()
  expect.truthy(panel.dead, 'a panel whose window died')
  expect.equal(env.tags:find 'implicit', nil, 'the tag only the placement held')
  expect.equal(env.tags:find 'primary', env.primary, 'a tag its owner made')
  expect.equal(#env.primary.members, 0, 'the membership ends at once')
  placement:dispose()

  env.window.dead = false
  local again, _, replaced = place(env, { height = 1, chrome = false })
  replaced:dispose()
  expect.truthy(again.dead, 'disposing a placement removes its panel')
  expect.equal(#env.primary.members, 0, 'the membership of the disposed placement')

  local last = place(env, { height = 1, chrome = false })
  env.consumer:disable()
  expect.truthy(last.dead, "an unloading owner's placement")
  expect.truthy(env.primary.dead, "an unloading owner's tag")
  expect.equal(#env.panels:all(), 0, 'the panels after the owner unloads')
  expect.equal(#env.tags:all(), 0, 'the tags after the owner unloads')
  env.session:close()
end)

return test
