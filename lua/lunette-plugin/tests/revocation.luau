-- Covers the view a consumer reads a provision through: it is frozen, it serves while the provider's
-- activation lasts, and it raises once that activation has ended, even for a reference the consumer kept.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local REVOKED = 'capability local/revocation-counter@1 is no longer available because its provider activation has ended'

local COUNTER = plugin.capability { name = 'local/revocation-counter', schema = 1 }
local DOUBLER = plugin.capability { name = 'local/revocation-doubler', schema = 1 }

-- A counter and a callable doubler, each read by two consumers. `env.kept` and `env.doubler` are the views
-- the last consumer to load read.
local function start()
  local env = { seen = {}, counter = COUNTER, doublerCapability = DOUBLER }
  local provider = plugin.define {
    name = 'provider',
    provides = { counter = env.counter, doubler = env.doublerCapability },
    init = function(_context, _config, publish)
      local count = 0
      local service = { LIMIT = 3 }
      function service.bump(self, by)
        count += by
        return self.LIMIT, count
      end
      function service.refuse(_self)
        error('the bump is refused', 2)
      end
      publish:provide(env.counter, service)
      publish:provide(
        env.doublerCapability,
        setmetatable({}, {
          __call = function(_self, value)
            return value * 2
          end,
        })
      )
    end,
  }
  local consumer = plugin.define {
    name = 'consumer',
    requires = { counter = env.counter, doubler = env.doublerCapability },
    init = function(context, config)
      env.seen[config.name] = context:require(env.counter)
      env.kept = env.seen[config.name]
      env.doubler = context:require(env.doublerCapability)
    end,
  }
  env.runtime = plugin.runtime()
  env.provider = env.runtime:use(provider, {})
  env.provider:enable()
  env.runtime:use(consumer, { name = 'first' }):enable()
  env.runtime:use(consumer, { name = 'second' }):enable()
  return env
end

test('consumers of one generation share a view that reads, calls, and iterates the provision', function()
  local env = start()
  expect.truthy(rawequal(env.seen.first, env.seen.second), 'the consumers share the view')
  local limit, count = env.kept:bump(2)
  expect.truthy(limit == 3 and count == 2, 'a method receives the view as self')
  expect.equal(env.doubler(21), 42, 'a callable provision stays callable')
  local fields = {}
  for key in env.kept do
    fields[key] = true
  end
  expect.truthy(fields.LIMIT and fields.bump, 'the view iterates the provision')
  local refused = expect.raises(function()
    env.kept:refuse()
  end, 'the bump is refused')
  expect.truthy(refused:find('revocation', 1, true), 'the error keeps the position it was raised at: ' .. refused)
  expect.falsy(refused:find('adapter', 1, true), 'the adapter adds no position: ' .. refused)
  env.runtime:close()
end)

test('a view raises on every write', function()
  local env = start()
  expect.raises(function()
    env.kept.LIMIT = 4
  end, 'capability local/revocation%-counter@1 is read%-only, so LIMIT cannot be assigned')
  expect.raises(function()
    env.kept.extra = true
  end, 'is read%-only')
  expect.raises(function()
    setmetatable(env.kept, nil)
  end, 'readonly')
  expect.truthy(env.kept.LIMIT == 3 and env.kept.extra == nil, 'the view is unchanged')
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
  expect.raises(function()
    return stale.LIMIT
  end, 'is no longer available', 'a field read')
  expect.raises(function()
    for _ in stale do
    end
  end, 'is no longer available', 'iteration')
  expect.raises(function()
    staleDoubler(1)
  end, 'local/revocation%-doubler@1 is no longer available', 'a call')
  -- A method read before revocation is a value like any other read. The view guards reads, not the provider
  -- state that a kept function closes over.
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
