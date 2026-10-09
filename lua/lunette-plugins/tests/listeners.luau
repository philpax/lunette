local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local listeners = require '../listeners'

local test = testing.suite()

local capability = plugin.capability { name = 'test/listeners', version = 1 }

-- The listeners belong to a provider, and a consumer of it owns the registrations.
local function start()
  local env = { native = testing.native() }
  env.session = testing.start {}
  env.session:use(adapter.define {
    name = 'listeners-provider',
    provides = { capability },
    init = function(context, _settings, publish)
      env.list = listeners.new(context)
      publish:provide(capability, env.list)
    end,
  })
  env.session:use(adapter.define {
    name = 'listeners-consumer',
    requires = { capability },
    init = function(context)
      env.owner = context
    end,
  })
  return env
end

local function deliver(env)
  env.list:each('listeners test', function(run)
    run()
  end)
end

test('delivery defers listeners added during it and skips one disposed during it', function()
  local env = start()
  local heard = {}
  local pending, late
  env.list:add(env.owner, function()
    heard[#heard + 1] = 'first'
    pending:dispose()
    if not late then
      late = env.list:add(env.owner, function()
        heard[#heard + 1] = 'late'
      end)
    end
  end)
  pending = env.list:add(env.owner, function()
    heard[#heard + 1] = 'disposed'
  end)
  deliver(env)
  expect.equal(table.concat(heard, ','), 'first', 'the registration snapshot and disposal check')
  deliver(env)
  expect.equal(table.concat(heard, ','), 'first,first,late', 'the next delivery reaches the new listener')
  env.session:close()
end)

test('a listener that raises is reported, and the listeners after it still run', function()
  local env = start()
  local heard = false
  env.list:add(env.owner, function()
    error 'listener failure'
  end)
  env.list:add(env.owner, function()
    heard = true
  end)
  deliver(env)
  expect.truthy(heard, 'a raising listener does not stop the next')
  expect.equal(#env.native.events.reported, 1, 'the reports')
  expect.truthy(env.native.events.reported[1].message:find('listener failure', 1, true), 'the reported failure')
  env.session:close()
end)

return test
