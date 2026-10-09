-- Covers adapter.define and plugin.capability specs and what a context reaches while it is current.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'

local test = testing.suite()

local function init() end

test('a malformed spec is rejected at the caller with the problem named', function()
  local message = expect.raises(function()
    adapter.define { name = 'typo', require = {}, init = init }
  end)
  expect.truthy(message:find '^@lunette%-plugin/tests/definition%.luau:%d+: ', 'the position: ' .. message)
  expect.truthy(
    message:find('plugin define: unknown field require; the fields are name, requires, provides, and init', 1, true),
    message
  )
end)

test('a context reaches only its declared capabilities, and only while it is current', function()
  local service = plugin.capability { name = 'local/reached-service', version = 1 }
  local extra = plugin.capability { name = 'local/reached-extra', version = 1 }
  local providerContext, consumerContext, escapedPublisher
  local calls = 0
  local provider = adapter.define {
    name = 'provider',
    provides = { service },
    init = function(context, _config, publish)
      providerContext = context
      escapedPublisher = publish
      publish:provide(service, { marker = 'original' })
    end,
  }
  local consumer = adapter.define {
    name = 'consumer',
    requires = { service },
    init = function(context)
      consumerContext = context
      expect.equal(context:require(service).marker, 'original', 'the declared service')
      expect.raises(function()
        context:require(extra)
      end, 'is not declared', 'an undeclared capability')
      calls += 1
    end,
  }

  local runtime = adapter.runtime()
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
  consumerInstance:requestReload {}
  runtime:drain()
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
  local child = adapter.define {
    name = 'child',
    init = function()
      loads += 1
    end,
  }
  local parent = adapter.define {
    name = 'parent',
    init = function(context)
      context:child(child)
    end,
  }
  local runtime = adapter.runtime()
  local function childState()
    for _, instance in runtime:snapshot().instances do
      if instance.parentId then
        return instance.state
      end
    end
    return nil
  end
  local parentInstance = runtime:use(parent, {})
  parentInstance:enable()
  expect.equal(loads, 1, 'the child loads once')
  expect.equal(childState(), 'active', 'the child')
  parentInstance:disable()
  expect.equal(childState(), nil, 'the child after its parent is disabled')
  runtime:close()
end)

test('a declaration is a list of distinct capabilities, keyed natively by contract', function()
  local service = plugin.capability { name = 'local/declared-service', version = 2 }
  for _, case in
    {
      { requires = { service, service }, message = 'requires lists capability local/declared%-service@2 twice' },
      { requires = { 'service' }, message = 'requires lists a string, not a capability' },
      { provides = { named = service }, message = 'provides is a list of capabilities, and named is not a position' },
      { requires = service, message = 'requires is a list of capabilities, and' },
    }
  do
    expect.raises(function()
      adapter.define { name = 'malformed', requires = case.requires, provides = case.provides, init = init }
    end, case.message)
  end
  local runtime = adapter.runtime()
  runtime
    :use(
      adapter.define {
        name = 'declared',
        provides = { service },
        init = function(_context, _config, publish)
          publish:provide(service, {})
        end,
      },
      {}
    )
    :enable()
  local provided = runtime:snapshot().instances[1].provided[1]
  expect.equal(provided.field, 'local/declared-service@2', 'the native field names the contract')
  runtime:close()
end)

return test
