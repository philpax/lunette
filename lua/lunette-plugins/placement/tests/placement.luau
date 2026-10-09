local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'
local rulesContract = require '@lunette-contracts/rules'
local placementContract = require '@lunette-contracts/placement'

local test = testing.suite()

local function start()
  local env = { native = testing.native() }
  env.session = testing.start {
    'theme',
    { id = 'panels', definition = require('@lunette-plugins/panels').definition, config = { rendering = 'layer' } },
    'tags',
    'rules',
    'placement',
  }
  env.consumer = env.session:use(plugin.define {
    name = 'placement-test',
    requires = {
      panels = panelsContract.capability,
      tags = tagsContract.capability,
      rules = rulesContract.capability,
      placement = placementContract.capability,
    },
    init = function(context)
      env.owner = context
      env.panels = context:require(panelsContract.capability)
      env.tags = context:require(tagsContract.capability)
      env.rules = context:require(rulesContract.capability)
      env.placement = context:require(placementContract.capability)
    end,
  })
  env.primary = env.tags:hold(env.owner, { name = 'primary', selected = true })
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

test('a failing release attempts every step once and raises the aggregate', function()
  local env = start()
  local panel, _, placement = place(env, { height = 1, chrome = false })
  local calls, order = {}, {}
  local function watch(target, method, name, failure)
    local original = target[method]
    target[method] = function(...)
      local result = original(...)
      calls[name] = (calls[name] or 0) + 1
      order[#order + 1] = name
      if failure then
        error(failure)
      end
      return result
    end
  end
  local implicit = env.tags:find 'implicit'
  watch(env.primary, 'remove', 'primary.remove', 'fixture: membership remove failure')
  watch(implicit, 'remove', 'implicit.remove')
  watch(panel, 'destroy', 'panel.destroy', 'fixture: panel destroy failure')

  local failure = expect.raises(function()
    placement:dispose()
  end, 'fixture: membership remove failure', 'the failing release')
  expect.truthy(failure:find('fixture: panel destroy failure', 1, true), 'the failures aggregate')
  for _, name in { 'primary.remove', 'implicit.remove', 'panel.destroy' } do
    expect.equal(calls[name], 1, 'the attempts of ' .. name)
  end
  expect.equal(order[#order], 'panel.destroy', 'the panel is destroyed after the memberships are removed')
  expect.truthy(panel.dead, 'the panel')
  env.session:close()
end)

test('a placement ends with its window, with its effect, and with its owner', function()
  local env = start()
  local panel, _, placement = place(env, { height = 1, chrome = false })
  env.window.dead = true
  env.panels:update()
  expect.truthy(panel.dead, 'a panel whose window died')
  expect.equal(#env.placement:placed(), 0, 'the live placements after the window dies')
  expect.equal(env.tags:find 'implicit', nil, 'the tag only the placement held')
  expect.equal(env.tags:find 'primary', env.primary, 'a tag its owner made')
  expect.equal(#env.primary:panels(), 0, 'the membership ends at once')
  placement:dispose()

  env.window.dead = false
  local again, _, replaced = place(env, { height = 1, chrome = false })
  replaced:dispose()
  expect.truthy(again.dead, 'disposing a placement removes its panel')
  expect.equal(#env.primary:panels(), 0, 'the membership of the disposed placement')

  local last = place(env, { height = 1, chrome = false })
  env.consumer:disable()
  expect.truthy(last.dead, "an unloading owner's placement")
  expect.truthy(env.primary.dead, "an unloading owner's tag")
  expect.equal(#env.panels:all(), 0, 'the panels after the owner unloads')
  expect.equal(#env.tags:all(), 0, 'the tags after the owner unloads')
  env.session:close()
end)

return test
