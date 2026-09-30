return function(plugin)
  local function identity(value)
    return value
  end

  local function rejects(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
  end

  local good = plugin.capability('local/failure-good', 1, identity)
  local missing = plugin.capability('local/failure-missing', 1, identity)
  local duplicate = plugin.capability('local/failure-duplicate', 1, identity)
  local nil_value = plugin.capability('local/failure-nil', 1, identity)
  local extra = plugin.capability('local/failure-extra', 1, identity)
  local undeclared = plugin.capability('local/failure-undeclared', 1, identity)
  local returned = plugin.capability('local/failure-returned', 1, identity)
  local escaped_success_token = plugin.capability('local/failure-escaped-success', 1, identity)
  local escaped_error_token = plugin.capability('local/failure-escaped-error', 1, identity)
  local cancelled = plugin.capability('local/failure-cancelled', 1, identity)
  local partial_one = plugin.capability('local/failure-partial-one', 1, identity)
  local partial_two = plugin.capability('local/failure-partial-two', 1, identity)
  local events = {}
  local published = {}
  local escaped_success
  local escaped_error
  local escaped_cancel
  local cancelled_instance

  local provider = plugin.define(identity, {}, { good = good }, function(_context, config, publish)
    publish:provide(good, config.value)
  end)
  local consumer = plugin.define(identity, { good = good }, {}, function(context, config)
    assert(context:require(good) == 'service')
    table.insert(published, config.name)
  end)
  local function failed_consumer(capability, name)
    return plugin.define(identity, { service = capability }, {}, function(context, config)
      context:require(capability)
      table.insert(published, config.name .. name)
    end)
  end

  local missing_definition = plugin.define(identity, {}, { missing = missing }, function(context)
    context:effect(function()
      table.insert(events, 'missing-acquire-outer')
      return function()
        table.insert(events, 'missing-release-outer')
      end
    end)
    context:effect(function()
      table.insert(events, 'missing-acquire-inner')
      return function()
        table.insert(events, 'missing-release-inner')
      end
    end)
  end)
  local duplicate_definition = plugin.define(
    identity,
    {},
    { duplicate = duplicate },
    function(context, _config, publish)
      context:effect(function()
        table.insert(events, 'duplicate-acquire')
        return function()
          table.insert(events, 'duplicate-release')
        end
      end)
      publish:provide(duplicate, 'first')
      publish:provide(duplicate, 'second')
    end
  )
  local nil_definition = plugin.define(identity, {}, { nil_value = nil_value }, function(context, _config, publish)
    context:effect(function()
      table.insert(events, 'nil-acquire')
      return function()
        table.insert(events, 'nil-release')
      end
    end)
    publish:provide(nil_value, nil)
  end)
  local extra_definition = plugin.define(identity, {}, { extra = extra }, function(context, _config, publish)
    context:effect(function()
      table.insert(events, 'extra-acquire')
      return function()
        table.insert(events, 'extra-release')
      end
    end)
    publish:provide(undeclared, 'extra')
  end)
  local returned_definition = plugin.define(identity, {}, { returned = returned }, function(context, _config, publish)
    context:effect(function()
      table.insert(events, 'returned-acquire')
      return function()
        table.insert(events, 'returned-release')
      end
    end)
    publish:provide(returned, 'staged')
    return 'initializer result'
  end)
  local escaped_success_definition = plugin.define(
    identity,
    {},
    { service = escaped_success_token },
    function(_context, config, publish)
      escaped_success = publish
      publish:provide(escaped_success_token, config.value)
    end
  )
  local escaped_success_consumer = failed_consumer(escaped_success_token, '-escaped-success')
  local escaped_error_definition = plugin.define(
    identity,
    {},
    { service = escaped_error_token },
    function(context, _config, publish)
      escaped_error = publish
      context:effect(function()
        table.insert(events, 'escaped-error-acquire')
        return function()
          table.insert(events, 'escaped-error-release')
        end
      end)
      publish:provide(escaped_error_token, { marker = 'staged-before-error' })
      error 'escaped initializer failure'
    end
  )
  local cancelled_definition = plugin.define(
    identity,
    {},
    { cancelled = cancelled },
    function(context, _config, publish)
      escaped_cancel = publish
      context:effect(function()
        table.insert(events, 'cancel-acquire')
        return function()
          table.insert(events, 'cancel-release')
        end
      end)
      cancelled_instance:disable()
      publish:provide(cancelled, 'cancelled')
    end
  )
  local cancelled_consumer = failed_consumer(cancelled, '-cancelled')
  local partial_definition = plugin.define(
    identity,
    {},
    { one = partial_one, two = partial_two },
    function(context, _config, publish)
      context:effect(function()
        table.insert(events, 'partial-acquire')
        return function()
          table.insert(events, 'partial-release')
        end
      end)
      publish:provide(partial_one, 'one')
      error 'partial initializer failure'
    end
  )
  local partial_consumer = failed_consumer(partial_one, '-partial')

  local runtime = plugin.runtime()
  local provider_instance = runtime:use(provider, { value = 'service' })
  local good_consumer_instance = runtime:use(consumer, { name = 'good-consumer' })
  provider_instance:enable()
  good_consumer_instance:enable()

  local function install_failure(definition, capability, name)
    local instance = runtime:use(definition, {})
    local dependent = runtime:use(failed_consumer(capability, name), { name = 'published' })
    dependent:enable()
    instance:enable()
  end

  install_failure(missing_definition, missing, '-missing')
  install_failure(duplicate_definition, duplicate, '-duplicate')
  install_failure(nil_definition, nil_value, '-nil')
  install_failure(extra_definition, extra, '-extra')
  install_failure(returned_definition, returned, '-returned')
  local escaped_success_instance = runtime:use(escaped_success_definition, { value = 'escaped' })
  local escaped_success_consumer_instance = runtime:use(escaped_success_consumer, { name = 'published' })
  escaped_success_instance:enable()
  escaped_success_consumer_instance:enable()
  local escaped_error_instance = runtime:use(escaped_error_definition, {})
  local escaped_error_consumer_instance =
    runtime:use(failed_consumer(escaped_error_token, '-escaped-error'), { name = 'published' })
  escaped_error_instance:enable()
  escaped_error_consumer_instance:enable()
  cancelled_instance = runtime:use(cancelled_definition, {})
  local cancelled_consumer_instance = runtime:use(cancelled_consumer, { name = 'published' })
  cancelled_instance:enable()
  cancelled_consumer_instance:enable()
  local partial_instance = runtime:use(partial_definition, {})
  local partial_consumer_instance = runtime:use(partial_consumer, { name = 'published' })
  partial_instance:enable()
  partial_consumer_instance:enable()

  assert(published[1] == 'good-consumer')
  assert(published[2] == 'published-escaped-success')
  assert(published[3] == nil)
  rejects(function()
    escaped_success:provide(escaped_success_token, 'late')
  end, 'initializer is no longer active')
  rejects(function()
    escaped_error:provide(escaped_error_token, 'late')
  end, 'initializer is no longer active')
  rejects(function()
    escaped_cancel:provide(cancelled, 'late')
  end, 'initializer is no longer active')
  runtime:drain()
  assert(events[1] == 'missing-acquire-outer')
  assert(events[2] == 'missing-acquire-inner')
  assert(events[3] == 'missing-release-inner')
  assert(events[4] == 'missing-release-outer')
  assert(events[5] == 'duplicate-acquire')
  assert(events[6] == 'duplicate-release')
  assert(events[7] == 'nil-acquire')
  assert(events[8] == 'nil-release')
  assert(events[9] == 'extra-acquire')
  assert(events[10] == 'extra-release')
  assert(events[11] == 'returned-acquire')
  assert(events[12] == 'returned-release')
  assert(events[13] == 'escaped-error-acquire')
  assert(events[14] == 'escaped-error-release')
  assert(events[15] == 'cancel-acquire')
  assert(events[16] == 'cancel-release')
  assert(events[17] == 'partial-acquire')
  assert(events[18] == 'partial-release')
  runtime:close()
  assert(events[19] == nil)
end
