-- Verifies the deferred native reload boundary used by session management.

local testing = require '@testing'
local plugin = require '@lunette-plugin'
local expect = testing.expect
local test = testing.suite()

test('requestReload accepts configuration without callbacks and rejection leaves removed instances unloaded', function()
  local observed, loads, releases = nil, 0, 0
  local definition = plugin.define {
    name = 'managed-deferred-reload',
    init = function(context, config)
      observed = config.value
      loads += 1
      context:effect(function()
        return function()
          releases += 1
        end
      end)
    end,
  }
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { value = 1 })
  instance:enable()
  instance:requestReload { value = 2 }
  expect.equal(observed, 1)
  expect.equal(loads, 1)
  expect.equal(releases, 0)
  expect.equal(instance:state(), 'active')
  expect.equal(runtime:snapshot().instances[1].replacementRequested, true)
  runtime:drain()
  expect.equal(observed, 2)
  expect.equal(loads, 2)
  expect.equal(releases, 1)
  instance:reload { value = 3 }
  expect.equal(observed, 3, 'ordinary reload retains automatic draining')
  instance:dispose()
  expect.raises(function()
    instance:requestReload { value = 4 }
  end)
  runtime:drain()
  expect.equal(loads, 3)
  expect.equal(observed, 3)
  expect.equal(instance:state(), 'removed')
  expect.equal(#runtime:snapshot().instances, 0)
  runtime:close()
end)

return test
