-- Covers the read-only view a consumer reads a provision through, and its revocation when the provider activation ends.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'

local test = testing.suite()

type Counter = {
  LIMIT: number,
  read bump: (Counter, number) -> (number, number),
  read refuse: (Counter) -> never,
}
type Doubler = setmetatable<{}, { __call: ({}, number) -> number }>
type Environment = {
  seen: { [string]: Counter },
  counter: plugin.Capability<Counter>,
  doublerCapability: plugin.Capability<Doubler>,
  kept: Counter?,
  doubler: Doubler?,
  runtime: adapter.Runtime?,
  provider: adapter.Instance<{}>?,
}

local REVOKED = 'capability local/revocation-counter@1 is no longer available because its provider activation has ended'

local COUNTER: plugin.Capability<Counter> = plugin.capability { name = 'local/revocation-counter', version = 1 }
local DOUBLER: plugin.Capability<Doubler> = plugin.capability { name = 'local/revocation-doubler', version = 1 }

-- A counter and a callable doubler, each read by two consumers. `env.kept` and `env.doubler` are the views
-- the last consumer to load read.
local function start(): Environment
  local env: Environment = { seen = {}, counter = COUNTER, doublerCapability = DOUBLER }
  local provider = adapter.define {
    name = 'provider',
    provides = { env.counter, env.doublerCapability },
    init = function(_context: adapter.Context, _config: {}, publish: adapter.Publisher)
      local count = 0
      local service = { LIMIT = 3 }
      function service.bump(self: Counter, by: number): (number, number)
        count += by
        return self.LIMIT, count
      end
      function service.refuse(_self: Counter): never
        error('the bump is refused', 2)
      end
      publish:provide(env.counter, service)
      publish:provide(
        env.doublerCapability,
        setmetatable({}, {
          __call = function(_self: {}, value: number): number
            return value * 2
          end,
        })
      )
    end,
  }
  local consumer = adapter.define {
    name = 'consumer',
    requires = { env.counter, env.doublerCapability },
    init = function(context: adapter.Context, config: { name: string })
      env.seen[config.name] = context:require(env.counter)
      env.kept = env.seen[config.name]
      env.doubler = context:require(env.doublerCapability)
    end,
  }
  env.runtime = adapter.runtime()
  env.provider = env.runtime:use(provider, {})
  env.provider:enable()
  env.runtime:use(consumer, { name = 'first' }):enable()
  env.runtime:use(consumer, { name = 'second' }):enable()
  return env
end

test('consumers of one generation share a view that reads, calls, iterates, and rejects writes', function()
  local env = start()
  expect.truthy(rawequal(env.seen.first, env.seen.second), 'the consumers share the view')
  local limit, count = env.kept:bump(2)
  expect.truthy(limit == 3 and count == 2, 'a method receives the view as self')
  expect.equal(env.doubler(21), 42, 'a callable provision stays callable')
  local fields: { [string]: boolean } = {}
  for key in env.kept do
    fields[key] = true
  end
  expect.truthy(fields.LIMIT and fields.bump, 'the view iterates the provision')
  local refused = expect.raises(function()
    env.kept:refuse()
  end, 'the bump is refused')
  expect.truthy(refused:find('revocation', 1, true), 'the error keeps the position it was raised at: ' .. refused)
  expect.falsy(refused:find('adapter', 1, true), 'the adapter adds no position: ' .. refused)
  expect.raises(function()
    env.kept.LIMIT = 4
  end, 'capability local/revocation%-counter@1 is read%-only, so LIMIT cannot be assigned')
  env.runtime:close()
end)

test('a kept view raises once its provider activation ends, and the next generation publishes a new one', function()
  local env = start()
  local stale, staleDoubler = env.kept, env.doubler
  local method = stale.bump
  env.provider:disable()
  local message = expect.raises(function()
    stale:bump(1)
  end, REVOKED:gsub('%p', '%%%0'))
  expect.truthy(message:find('revocation', 1, true), 'a revoked read names the consumer: ' .. message)
  expect.raises(function(): number
    return stale.LIMIT
  end, 'is no longer available', 'a field read')
  expect.raises(function()
    staleDoubler(1)
  end, 'local/revocation%-doubler@1 is no longer available', 'a call')
  -- The view guards reads, not the provider state that a method read before revocation closes over.
  expect.equal(type(method), 'function', 'a method read before revocation')

  env.provider:enable()
  expect.falsy(rawequal(env.kept, stale), 'a new generation publishes a new view')
  expect.equal(select(2, env.kept:bump(1)), 1, 'the new generation serves its consumers')
  expect.raises(function()
    stale:bump(1)
  end, 'is no longer available', 'the old view after the new generation')
  env.runtime:close()
end)

return test
