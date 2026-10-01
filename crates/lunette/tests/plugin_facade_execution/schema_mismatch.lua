-- A consumer that requires another schema of a contract than its provider
-- publishes is not activated, and its diagnostic names both schemas.
return function(plugin)
  local function identity(value)
    return value
  end

  local first = plugin.capability('local/schema-mismatch', 1, identity)
  local second = plugin.capability('local/schema-mismatch', 2, identity)
  local loaded = false
  local provider = plugin.define(identity, {}, { service = first }, function(_context, _config, publish)
    publish:provide(first, { version = 1 })
  end)
  local consumer = plugin.define(identity, { service = second }, {}, function()
    loaded = true
  end)

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
