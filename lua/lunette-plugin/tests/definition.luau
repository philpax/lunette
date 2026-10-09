-- Covers plugin.define and plugin.capability specs and what a context reaches while it is current.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local function init() end

test('a malformed spec is rejected at the caller with the problem named', function()
  local message = expect.raises(function()
    plugin.define { name = 'typo', require = {}, init = init }
  end)
  expect.truthy(message:find '^@lunette%-plugin/tests/definition%.luau:%d+: ', 'the position: ' .. message)
  expect.truthy(
    message:find('plugin define: unknown field require; the fields are name, requires, provides, and init', 1, true),
    message
  )
end)

test('a context reaches only its declared capabilities, and only while it is current', function()
  local service = plugin.capability { name = 'local/reached-service', schema = 1 }
  local extra = plugin.capability { name = 'local/reached-extra', schema = 1 }
  local providerContext, consumerContext, escapedPublisher
  local calls = 0
  local provider = plugin.define {
    name = 'provider',
    provides = { source = service },
    init = function(context, _config, publish)
      providerContext = context
      escapedPublisher = publish
      publish:provide(service, { marker = 'original' })
    end,
  }
  local consumer = plugin.define {
    name = 'consumer',
    requires = { source = service },
    init = function(context)
      consumerContext = context
      expect.equal(context:require(service).marker, 'original', 'the declared service')
      expect.raises(function()
        context:require(extra)
      end, 'is not declared', 'an undeclared capability')
      calls += 1
    end,
  }

  local runtime = plugin.runtime()
  local providerInstance = runtime:use(provider, {})
  local consumerInstance = runtime:use(consumer, {})
  consumerInstance:enable()
  providerInstance:enable()
  expect.equal(calls, 1, 'the consumer loads once its provider is active')
  providerContext:checkOwner(consumerContext)
  expect.raises(function()
    escapedPublisher:provide(service, {})
  end, 'initializer is no longer active', 'a publisher kept past its initializer')

  local old = consumerContext
  consumerInstance:reload {}
  expect.truthy(calls == 2 and consumerContext ~= old, 'a reload makes a new context')
  expect.raises(function()
    old:require(service)
  end, 'stale', 'the context before the reload')
  consumerInstance:disable()
  expect.raises(function()
    consumerContext:require(service)
  end, 'stale', 'the context after a disable')
  runtime:close()
end)

test('a child is enabled when it is installed and removed with the activation that installed it', function()
  local loads = 0
  local child = plugin.define {
    name = 'child',
    init = function()
      loads += 1
    end,
  }
  local installed
  local parent = plugin.define {
    name = 'parent',
    init = function(context)
      installed = context:child(child, {})
    end,
  }
  local runtime = plugin.runtime()
  local parentInstance = runtime:use(parent, {})
  parentInstance:enable()
  expect.equal(installed:state(), 'active', 'the child')
  installed:enable()
  expect.equal(loads, 1, 'enabling an enabled child changes nothing')
  parentInstance:disable()
  expect.equal(installed:state(), 'removed', 'the child after its parent is disabled')
  runtime:close()
end)

return test
