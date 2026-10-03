-- Covers plugin.define and plugin.capability: what a spec may hold, what a definition freezes, and what a
-- context reaches while it is current.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local function init() end

test('a malformed spec is rejected at the caller with the problem named', function()
  local cases = {
    {
      function()
        plugin.define { name = 'typo', require = {}, init = init }
      end,
      'plugin define: unknown field require; the fields are name, requires, provides, and init',
    },
    {
      function()
        plugin.define { name = '', init = init }
      end,
      'plugin define: name is empty',
    },
    {
      function()
        plugin.define { name = 'bad-requires', requires = 'panels', init = init }
      end,
      'plugin define: requires is a table of capabilities, not a string',
    },
    {
      function()
        plugin.define(init)
      end,
      'plugin define: a definition is a table of fields, not a function',
    },
    {
      function()
        plugin.capability { name = 'local/fractional', schema = 1.5 }
      end,
      'plugin capability: schema is a positive integer, not 1.5',
    },
  }
  for _, case in cases do
    local message = expect.raises(case[1], nil, case[2])
    expect.truthy(
      message:find '^@lunette%-plugin/tests/definition%.luau:%d+: ',
      'the error points at the caller: ' .. message
    )
    expect.equal(message:sub(-#case[2]), case[2], 'the message')
  end
end)

test('a definition without requires or provides declares empty tables', function()
  local named = plugin.define { name = 'named', init = init }
  expect.equal(named.name, 'named', 'the name')
  expect.equal(next(named.requires), nil, 'the requirements')
  expect.equal(next(named.provides), nil, 'the provisions')
end)

test('a plain table is not a capability', function()
  expect.raises(function()
    plugin.define {
      name = 'plain',
      requires = { source = { name = 'local/plain', schema = 1 } },
      init = init,
    }
  end, 'unbound capability wrapper')
end)

test('a definition freezes what it declares, whatever happens to the table it was given', function()
  local service = plugin.capability { name = 'local/declared-service', schema = 1 }
  local extra = plugin.capability { name = 'local/declared-extra', schema = 1 }
  local provisions = { source = service }
  local provider = plugin.define { name = 'provider', provides = provisions, init = init }
  provisions.source = extra
  expect.equal(provider.provides.source, service, 'the declared provision')
  expect.truthy(table.isfrozen(provider) and table.isfrozen(provider.provides), 'the definition is frozen')
  expect.truthy(table.isfrozen(service), 'the capability is frozen')
  expect.raises(function()
    provider.provides.source = extra
  end, 'readonly')
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
