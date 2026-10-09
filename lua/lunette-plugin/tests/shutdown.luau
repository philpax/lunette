-- Covers what the host's plugin shutdown ends: a provision kept alive only by an escaped publisher is
-- released, and a capability made before it is retired. Each case shuts the plugin runtimes down, which
-- retires every capability made so far, so each makes its own.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

test('a provision held only by an escaped publisher is released by the shutdown', function()
  local service = plugin.capability { name = 'local/payload-service', schema = 1 }
  local payload: {}? = {}
  local witness = setmetatable({ payload = payload }, { __mode = 'v' })
  local escaped
  local runtime = plugin.runtime()
  runtime
    :use(
      plugin.define {
        name = 'provider',
        provides = { service = service },
        init = function(_context, config, publish)
          escaped = publish
          publish:provide(service, config.payload)
        end,
      },
      { payload = payload }
    )
    :enable()
  payload = nil
  testing.collect()
  expect.truthy(witness.payload, 'the provision is held while its provider is active')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  testing.collect()
  expect.equal(witness.payload, nil, 'the provision after the shutdown')
  expect.truthy(escaped, 'the publisher is still referenced')
end)

test('a capability made before the shutdown is named as retired', function()
  local old = plugin.capability { name = 'local/retired', schema = 1 }
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  expect.raises(function()
    plugin.define { name = 'retired', requires = { old = old }, init = function() end }
  end, "the token in declaration field 'old' is from a retired epoch")
end)

return test
