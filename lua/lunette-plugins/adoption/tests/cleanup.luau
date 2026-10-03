-- Covers an adoption whose cleanup fails: every cleanup step is still attempted, the failures aggregate,
-- and the caller and the provider are quarantined.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adoptionContract = require '@lunette-contracts/adoption'
local panelsContract = require '@lunette-contracts/panels'
local tagsContract = require '@lunette-contracts/tags'

local test = testing.suite()

-- The providers adoption needs over the fake native API, and an independent consumer of panels and tags
-- whose context is `observer`.
local function start()
  local env = { native = testing.native() }
  env.session = testing.start { 'panels', 'tags', 'rules', 'placement', 'adoption' }
  env.session:use(plugin.define {
    name = 'cleanup-test-observer',
    requires = { panels = panelsContract.capability, tags = tagsContract.capability },
    init = function(context)
      env.panels = context:require(panelsContract.capability)
      env.tags = context:require(tagsContract.capability)
      env.observer = context
    end,
  })
  return env
end

test('a failing cleanup attempts every step once, aggregates, and quarantines the caller', function()
  local env = start()
  local fake = env.native
  local calls, order = {}, {}
  local function record(name)
    calls[name] = (calls[name] or 0) + 1
    order[#order + 1] = name
  end
  -- Wraps `target[method]` so each call during the failing cleanup is recorded under `name` and raises
  -- `failure`, when one is given, after the call.
  local failing = true
  local function watch(target, method, name, failure)
    local original = target[method]
    target[method] = function(...)
      local result = original(...)
      if not failing then
        return result
      end
      record(name)
      if failure then
        error(failure)
      end
      return result
    end
  end

  -- A panel and tag that belong to someone else, which the failing cleanup must leave alone.
  local unrelatedSource = fake.newWindow(1201)
  local unrelatedPanel = env.panels:fromWindow(env.observer, unrelatedSource)
  local unrelatedClaim = fake.events.claims[#fake.events.claims]
  local unrelatedTag = env.tags:new(env.observer, 'unrelated-cleanup-tag')
  unrelatedTag:add(env.observer, unrelatedPanel)

  local ordinary = env.tags:new(env.observer, 'ordinary-cleanup-tag')
  local throwing = env.tags:new(env.observer, 'throwing-cleanup-tag')
  watch(ordinary, 'remove', 'ordinary.remove')
  watch(throwing, 'remove', 'throwing.remove', 'fixture: membership remove failure')

  local weak = setmetatable({}, { __mode = 'v' })
  local callerOwner
  local loads = 0
  local caller = env.session.runtime:use(
    plugin.define {
      name = 'cleanup-test-caller',
      requires = { adoption = adoptionContract.capability },
      init = function(context)
        callerOwner = context
        loads += 1
      end,
    },
    {}
  )
  caller:enable()
  local adoption = env.session:observe(adoptionContract.capability).service
  local panel, started
  do
    local source = fake.newWindow(1202)
    weak[1] = source
    fake.events.windows = { source }
    started = adoption:start(callerOwner, {
      defaults = { tags = { 'first-cleanup-implicit', 'second-cleanup-implicit', ordinary, throwing } },
      onPlaced = function(created)
        panel = created
      end,
    })
    fake.events.windows = {}
  end
  local claim = fake.events.claims[#fake.events.claims]
  watch(claim, 'release', 'claim.release')
  for _, name in { 'first-cleanup-implicit', 'second-cleanup-implicit' } do
    watch(env.tags:find(name), 'remove', name .. '.remove')
  end
  watch(panel, 'destroy', 'panel.destroy', 'fixture: panel destroy failure')

  local failure = expect.raises(function()
    started:dispose()
  end, 'fixture: membership remove failure', 'the failing cleanup')
  failing = false
  expect.truthy(failure:find('fixture: panel destroy failure', 1, true), 'the failures aggregate')
  for _, name in
    {
      'throwing.remove',
      'ordinary.remove',
      'first-cleanup-implicit.remove',
      'second-cleanup-implicit.remove',
      'panel.destroy',
      'claim.release',
    }
  do
    expect.equal(calls[name], 1, 'the attempts of ' .. name)
  end
  -- Memberships are removed, most recent first, before the panel is destroyed.
  expect.equal(order[1], 'throwing.remove', 'the first removal')
  expect.equal(order[2], 'ordinary.remove', 'the second removal')
  expect.truthy(
    table.find(order, 'claim.release') > table.find(order, 'first-cleanup-implicit.remove'),
    'the claim is released after the memberships are removed'
  )
  expect.truthy(panel.dead and claim.dead, 'the panel and its claim')
  expect.falsy(env.tags:find 'first-cleanup-implicit', 'the first tag placement made')
  expect.falsy(env.tags:find 'second-cleanup-implicit', 'the second tag placement made')
  expect.truthy(not ordinary.dead and #ordinary.members == 0, 'the ordinary tag keeps living, emptied')
  expect.truthy(not throwing.dead and #throwing.members == 0, 'the throwing tag keeps living, emptied')
  expect.equal(env.panels:forSource(unrelatedSource), unrelatedPanel, 'the unrelated panel')
  expect.falsy(unrelatedClaim.dead, 'the unrelated claim')
  expect.truthy(unrelatedTag:has(unrelatedPanel), 'the unrelated membership')

  expect.falsy(callerOwner:active(), 'the caller after its cleanup failed')
  expect.raises(function()
    caller:enable()
  end, nil, 'enabling the quarantined caller')
  expect.equal(loads, 1, 'the loads of the caller')
  expect.equal(fake.subscriptionCount 'onWindowOpened', 0, 'the subscriptions')
  local duplicate = env.session.runtime:use(require('@lunette-plugins/adoption').definition, {})
  expect.raises(function()
    duplicate:enable()
  end, nil, 'a second adoption provider, while the failed one keeps its reservation')
  started:dispose()
  expect.falsy(panel:destroy(), 'destroying the panel again')

  env.session:close()
  panel, started = nil, nil
  fake.dropEndedSubscriptions()
  testing.collect()
  testing.collect()
  expect.equal(weak[1], nil, 'the window after close')
end)

return test
