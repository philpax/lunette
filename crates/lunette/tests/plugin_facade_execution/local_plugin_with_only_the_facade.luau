return function(plugin)
  local clock = plugin.capability { name = 'local/clock', schema = 1 }
  local pulse = plugin.capability { name = 'local/pulse', schema = 1 }
  local child_contract = plugin.capability { name = 'local/child', schema = 1 }
  local clock_value = { kind = 'clock' }
  local pulse_value = { kind = 'pulse' }
  local events = {}
  local owner_context
  local child_config_value

  local child_definition = plugin.define {
    name = 'child-definition',
    provides = { child = child_contract },
    init = function(context, config, publish)
      child_config_value = config.value
      assert(context:active())
      context:effect(function()
        table.insert(events, 'child-acquire')
        return function()
          table.insert(events, 'child-release')
        end
      end)
      publish:provide(child_contract, config.value)
    end,
  }

  local provider_definition = plugin.define {
    name = 'provider-definition',
    provides = { clock = clock, pulse = pulse },
    init = function(context, config, publish)
      owner_context = context
      context:child(child_definition, { value = config.clock }):enable()
      context:effect(function()
        table.insert(events, 'provider-acquire')
        return function()
          table.insert(events, 'provider-release')
        end
      end)
      publish:provide(clock, config.clock)
      publish:provide(pulse, config.pulse)
    end,
  }
  local consumer_definition = plugin.define {
    name = 'consumer-definition',
    requires = { clock = clock, pulse = pulse },
    init = function(context, config)
      assert(context:require(clock).kind == 'clock')
      assert(context:require(pulse).kind == 'pulse')
      owner_context:checkOwner(context)
      context:effect(function()
        table.insert(events, config.name .. '-acquire')
        return function()
          table.insert(events, config.name .. '-release')
        end
      end)
    end,
  }

  local runtime = plugin.runtime()
  local provider = runtime:use(provider_definition, {
    clock = clock_value,
    pulse = pulse_value,
  })
  local first_consumer = runtime:use(consumer_definition, { name = 'first' })
  local second_consumer = runtime:use(consumer_definition, { name = 'second' })
  provider:enable()
  first_consumer:enable()
  second_consumer:enable()

  local reload_events = {}
  local reload_definition = plugin.define {
    name = 'reload-definition',
    init = function(context, config)
      table.insert(reload_events, 'load-' .. config.value)
      context:effect(function()
        return function()
          table.insert(reload_events, 'release-' .. config.value)
        end
      end)
    end,
  }
  local reload_instance = runtime:use(reload_definition, { value = 'one' })
  reload_instance:enable()
  reload_instance:reload { value = 'two' }
  assert(reload_events[1] == 'load-one')
  assert(reload_events[2] == 'release-one')
  assert(reload_events[3] == 'load-two')

  local other_runtime = plugin.runtime()
  local owner_probe = plugin.define {
    name = 'owner-probe',
    init = function(context)
      local ok, message = pcall(function()
        owner_context:checkOwner(context)
      end)
      assert(not ok and tostring(message):find('caller belongs to another runtime', 1, true), tostring(message))
    end,
  }
  local probe = other_runtime:use(owner_probe, {})
  probe:enable()
  other_runtime:close()

  runtime:close()
  assert(rawequal(child_config_value, clock_value))
  assert(events[1] == 'provider-acquire')
  assert(events[2] == 'child-acquire')
  assert(events[3] == 'first-acquire')
  assert(events[4] == 'second-acquire')
  assert(events[5] == 'first-release')
  assert(events[6] == 'second-release')
  assert(events[7] == 'child-release')
  assert(events[8] == 'provider-release')
  assert(reload_events[4] == 'release-two')
end
