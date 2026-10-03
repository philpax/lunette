-- Covers the panels provider's arrival and removal listeners, including one that raises while a reload
-- drains the provider's dependents.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

-- The panels provider over the fake native API, and a consumer of it whose context is `owner`.
local function start()
  local env = { native = testing.native() }
  env.session = testing.start { 'panels' }
  env.consumer = env.session:use(plugin.define {
    name = 'listeners-test',
    requires = { panels = panelsContract.capability },
    init = function(context)
      env.panels = context:require(panelsContract.capability)
      env.owner = context
    end,
  })
  return env
end

test('listeners hear arrivals and removals, and a raising listener is reported while the others run', function()
  local env = start()
  local listener = env.session:observe(panelsContract.capability)
  local added, removed, everything = {}, {}, {}
  listener.service:onAdded(listener.context, function(created)
    added[#added + 1] = created
  end)
  listener.service:onAdded(listener.context, function()
    error 'arrival listener failed'
  end)
  local first = env.panels:fromWindow(env.owner, env.native.newWindow(1), { height = 1 })
  local second = env.panels:fromWindow(env.owner, env.native.newWindow(2), { height = 1 })
  expect.equal(#added, 2, 'the arrivals heard')
  expect.equal(added[1], first, 'the first arrival')

  local removal = listener.service:onRemoved(listener.context, {
    panel = first,
    run = function(target)
      removed[#removed + 1] = target
    end,
  })
  listener.service:onRemoved(listener.context, {
    run = function()
      error 'removal listener failed'
    end,
  })
  listener.service:onRemoved(listener.context, {
    run = function(target)
      everything[#everything + 1] = target
    end,
  })
  second:destroy(env.owner)
  expect.equal(#removed, 0, 'a listener for one panel does not hear another')
  first:destroy(env.owner)
  expect.equal(#removed, 1, 'the removals of the first panel heard')
  expect.equal(removed[1], first, 'the removed panel')
  expect.equal(#everything, 2, 'a listener after a raising one hears every removal')
  removal:dispose()

  local reported = env.native.events.reported
  expect.equal(#reported, 4, 'the reports')
  expect.truthy(reported[1].message:find('arrival listener failed', 1, true), 'the arrival report')
  expect.truthy(reported[3].message:find('removal listener failed', 1, true), 'the removal report')

  -- A listener ends with its owner.
  listener.instance:disable()
  env.panels:fromWindow(env.owner, env.native.newWindow(3), { height = 1 })
  expect.equal(#added, 2, 'the arrivals heard after the listener ended')
  env.session:close()
end)

test('a removal listener that raises during a drain fails neither the drain nor the removing cleanup', function()
  local env = start()
  local panels = env.session.instances.panels
  -- The creator is installed first, so a drain unloads it before the listener, and its cleanup removes the
  -- panel while the listener still hears.
  local created = 0
  local creator = env.session.runtime:use(
    plugin.define {
      name = 'listeners-test-creator',
      requires = { panels = panelsContract.capability },
      init = function(context)
        context:require(panelsContract.capability):fromWindow(context, env.native.newWindow(23), { height = 1 })
        created += 1
      end,
    },
    {}
  )
  local heard = 0
  local listener = env.session:use(plugin.define {
    name = 'listeners-test-listener',
    requires = { panels = panelsContract.capability },
    init = function(context)
      context:require(panelsContract.capability):onRemoved(context, {
        run = function()
          heard += 1
          error 'removal listener failed during a drain'
        end,
      })
    end,
  })
  creator:enable()
  expect.equal(created, 1, 'the loads of the creator')

  -- Reloading the provider drains both dependents, unloads and loads the provider, and loads both
  -- dependents again in one drain.
  panels:reload {}
  expect.equal(heard, 1, 'the removals the listener heard')
  expect.equal(panels:state(), 'active', 'the provider')
  expect.equal(creator:state(), 'active', 'the creator, which the drain went on to load')
  expect.equal(listener:state(), 'active', 'the listener')
  expect.equal(created, 2, 'the loads of the creator after the reload')

  creator:disable()
  expect.equal(heard, 2, 'the reloaded listener hears the next removal')
  expect.equal(creator:state(), 'inactive', 'the creator whose cleanup removed the panel')
  expect.equal(creator:diagnostic(), nil, 'the diagnostic of the creator')

  local reported = env.native.events.reported
  expect.equal(#reported, 2, 'each raising delivery is reported')
  for _, report in reported do
    expect.truthy(report.message:find('removal listener failed during a drain', 1, true), report.message)
  end
  env.session:close()
end)

return test
