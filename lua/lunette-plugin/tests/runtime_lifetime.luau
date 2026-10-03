-- Covers what keeps the native runtime's resources alive and what releases them: a runtime collected while its
-- instances are active, a close that outruns the request queue, and the host's plugin shutdown. The shutdown
-- cases come last, since shutdown retires every runtime in the state.
local testing = require '@testing'
local expect = testing.expect
local plugin = require('@lunette').plugin

local test = testing.suite()

test('an active instance survives the collection of its runtime userdata', function()
  local escaped
  local definition = plugin.define({}, {}, function(context)
    escaped = context
    context:effect(function()
      return function() end
    end)
    return {}
  end)
  local runtime = plugin.runtime()
  runtime:use(definition, {}):enable()
  runtime = nil
  testing.collect()
  expect.truthy(escaped:active(), 'the context after its runtime was collected')
end)

test('close releases every effect, ahead of the request queue and its action limits', function()
  local released = 0
  local definition = plugin.define({}, {}, function(context)
    context:effect(function()
      return function()
        released += 1
      end
    end)
    return {}
  end)
  local runtime = plugin.runtime()
  for _ = 1, 300 do
    runtime:use(definition, {}):enable()
  end
  runtime:close()
  expect.equal(released, 300, 'the effects released by close')

  local other = plugin.runtime()
  local pending = {}
  for index = 1, 300 do
    pending[index] = other:use(definition, {})
  end
  other
    :use(
      plugin.define({}, {}, function(context)
        context:effect(function()
          return function()
            released += 1
          end
        end)
        for index = 1, 300 do
          pcall(function()
            pending[index]:enable()
          end)
        end
        other:close()
        return {}
      end),
      {}
    )
    :enable()
  expect.equal(released, 301, 'the close queued behind 300 requests keeps its priority')
  expect.raises(function()
    other:use(definition, {})
  end, nil, 'using the closed runtime')
end)

test('the plugin shutdown releases a leaked effect payload', function()
  local definition = plugin.define({}, {}, function(context, config)
    context:effect(function()
      return function()
        config.released = true
      end
    end)
    return {}
  end)
  local payload = { released = false }
  plugin.runtime():use(definition, payload):enable()
  expect.falsy(payload.released, 'the payload before shutdown')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  expect.truthy(payload.released, 'the payload after shutdown')
end)

test('the plugin shutdown releases what an escaped definition initializer references', function()
  local witness = setmetatable({}, { __mode = 'v' })
  local escaped = (function()
    local referenced = {}
    witness.referenced = referenced
    return plugin.define({}, {}, function()
      local _ = referenced
      return {}
    end)
  end)()
  testing.collect()
  expect.truthy(witness.referenced, 'the reference before shutdown')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  testing.collect()
  expect.equal(witness.referenced, nil, 'the reference after shutdown')
  expect.truthy(escaped, 'the definition outlives the shutdown')
end)

return test
