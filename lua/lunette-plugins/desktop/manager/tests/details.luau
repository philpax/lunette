local testing = require '@testing'
local plugin = require '@lunette-plugin'
local projection = require '@lunette-plugins/desktop/manager/projection'
local details = require '@lunette-plugins/desktop/manager/details'
local expect = testing.expect
local test = testing.suite()

test('instance details include exact effects and lifecycle records without callbacks', function()
  local runtime = plugin.runtime()
  local effect
  local definition = plugin.define {
    name = 'detail-source',
    init = function(context, _config, _publish)
      effect = context:effect(function()
        return function() end
      end)
    end,
  }
  local instance = runtime:use(definition, {})
  instance:enable()
  runtime:drain()
  local function lines()
    local projected = projection.snapshot(runtime:snapshot())
    return table.concat(
      details.lines(projected, { kind = 'node', id = instance:id() }, {}, {}, function()
        return nil
      end),
      '\n'
    )
  end
  local active = lines()
  expect.truthy(active:find 'detail%-source', 'instance name')
  expect.truthy(active:find('State: active', 1, true), 'phase')
  expect.truthy(active:find('Native effects:', 1, true), 'actual acquisitions listed')
  expect.truthy(active:find('armed', 1, true), 'effect state')
  effect:dispose()
  expect.truthy(lines():find('disarmed', 1, true), 'disposed effect history')
  instance:disable()
  runtime:drain()
  expect.truthy(lines():find('enabled: false', 1, true), 'disabled intent')
  runtime:close()
end)

test('missing selections and unconfigured entries produce explicit details', function()
  local projected = projection.snapshot {
    instances = {},
    draining = false,
    closing = false,
    closed = false,
  }
  expect.equal(
    details.lines(projected, { kind = 'node', id = 'missing' }, {}, {}, function()
      return nil
    end)[1],
    'The selected instance is no longer present.',
    'missing selection'
  )
  expect.equal(
    details.lines(projected, nil, {}, {}, function()
      return nil
    end)[1],
    'Select a node or relationship.',
    'empty selection'
  )
end)

return test
