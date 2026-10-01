-- A consumer that requires another schema of a contract than its provider
-- publishes is not activated, and its diagnostic names both schemas.
return function(plugin)
  local first = plugin.capability { name = 'local/schema-mismatch', schema = 1 }
  local second = plugin.capability { name = 'local/schema-mismatch', schema = 2 }
  local loaded = false
  local provider = plugin.define {
    name = 'provider',
    provides = { service = first },
    init = function(_context, _config, publish)
      publish:provide(first, { version = 1 })
    end,
  }
  local consumer = plugin.define {
    name = 'consumer',
    requires = { service = second },
    init = function()
      loaded = true
    end,
  }

  local runtime = plugin.runtime()
  local providerInstance = runtime:use(provider, {})
  local consumerInstance = runtime:use(consumer, {})
  providerInstance:enable()
  consumerInstance:enable()
  runtime:drain()
  assert(not loaded, 'a schema mismatch must not activate the consumer')
  assert(consumerInstance:state() == 'inactive', consumerInstance:state())
  local diagnostic = tostring(consumerInstance:diagnostic())
  assert(diagnostic:find('local/schema-mismatch', 1, true), diagnostic)
  assert(diagnostic:find('requires', 1, true), diagnostic)
  return diagnostic
end
