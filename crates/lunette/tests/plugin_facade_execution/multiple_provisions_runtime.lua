return function(plugin)
  local function identity(value)
    return value
  end

  local function rejects(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
  end

  local first = plugin.capability('local/multiple-first', 1, identity)
  local second = plugin.capability('local/multiple-second', 1, identity)
  local missing = plugin.capability('local/multiple-missing', 1, identity)
  local spare = plugin.capability('local/multiple-spare', 1, identity)
  local duplicate = plugin.capability('local/multiple-duplicate', 1, identity)
  local nil_value = plugin.capability('local/multiple-nil', 1, identity)
  local staged_first = plugin.capability('local/multiple-staged-first', 1, identity)
  local staged_second = plugin.capability('local/multiple-staged-second', 1, identity)
  local unknown = plugin.capability('local/multiple-unknown', 1, identity)
  local extra = plugin.capability('local/multiple-extra', 1, identity)
  local first_value = { marker = 'first' }
  local second_value = { marker = 'second' }
  local failed_events = {}
  local staged_events = {}
  local published_consumers = {}
  local consumer_events = {}

  local provider = plugin.define(identity, {}, { first = first, second = second }, function(_context, config, publish)
    publish:provide(first, config.first)
    assert(#consumer_events == 0)
    publish:provide(second, config.second)
    assert(#consumer_events == 0)
  end)
  local consumer = plugin.define(identity, { second = second, first = first }, {}, function(context, config)
    assert(rawequal(context:require(first), first_value))
    assert(rawequal(context:require(second), second_value))
    table.insert(consumer_events, config.name)
    table.insert(published_consumers, config.name)
  end)
  local bad_missing = plugin.define(identity, {}, { missing = missing }, function(context, _config, publish)
    context:effect(function()
      table.insert(failed_events, 'missing-acquire')
      return function()
        table.insert(failed_events, 'missing-release')
      end
    end)
    publish:provide(missing, nil)
  end)
  local bad_extra = plugin.define(identity, {}, { spare = spare }, function(context, _config, publish)
    context:effect(function()
      table.insert(failed_events, 'extra-acquire')
      return function()
        table.insert(failed_events, 'extra-release')
      end
    end)
    rejects(function()
      publish:provide(extra, 'not declared')
    end, 'capability is not declared')
  end)
  local bad_duplicate = plugin.define(identity, {}, { duplicate = duplicate }, function(_context, _config, publish)
    publish:provide(duplicate, 'first')
    publish:provide(duplicate, 'second')
  end)
  local recovered = plugin.define(identity, {}, { unknown = unknown }, function(_context, _config, publish)
    rejects(function()
      publish:provide(extra, 'unknown')
    end, 'capability is not declared')
    publish:provide(unknown, 'known')
  end)
  local bad_return = plugin.define(identity, {}, { nil_value = nil_value }, function(_context, _config, publish)
    publish:provide(nil_value, 'staged')
    return 'initializer result'
  end)
  local staged = plugin.define(
    identity,
    {},
    { staged = staged_first, staged_second = staged_second },
    function(context, _config, publish)
      context:effect(function()
        table.insert(staged_events, 'acquire')
        return function()
          table.insert(staged_events, 'release')
        end
      end)
      publish:provide(staged_first, 'one')
      publish:provide(staged_second, 'two')
    end
  )

  local runtime = plugin.runtime()
  local provider_instance = runtime:use(provider, {
    first = first_value,
    second = second_value,
  })
  local first_consumer = runtime:use(consumer, { name = 'first-consumer' })
  local second_consumer = runtime:use(consumer, { name = 'second-consumer' })
  local missing_instance = runtime:use(bad_missing, {})
  local extra_instance = runtime:use(bad_extra, {})
  local duplicate_instance = runtime:use(bad_duplicate, {})
  local recovered_instance = runtime:use(recovered, {})
  local return_instance = runtime:use(bad_return, {})
  local staged_instance = runtime:use(staged, {})
  first_consumer:enable()
  second_consumer:enable()
  assert(#consumer_events == 0)
  provider_instance:enable()
  missing_instance:enable()
  extra_instance:enable()
  duplicate_instance:enable()
  recovered_instance:enable()
  return_instance:enable()
  staged_instance:enable()

  assert(consumer_events[1] == 'first-consumer')
  assert(consumer_events[2] == 'second-consumer')
  assert(consumer_events[3] == nil)
  assert(published_consumers[1] == 'first-consumer')
  assert(published_consumers[2] == 'second-consumer')
  runtime:drain()
  assert(failed_events[1] == 'missing-acquire')
  assert(failed_events[2] == 'missing-release')
  assert(failed_events[3] == 'extra-acquire')
  assert(failed_events[4] == 'extra-release')
  assert(staged_events[1] == 'acquire')
  runtime:close()
  assert(staged_events[2] == 'release')
  assert(staged_events[3] == nil)
end
