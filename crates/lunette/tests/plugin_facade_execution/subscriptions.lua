-- Context:on registers a subscription as an effect of the activation. An
-- instance reload cancels the old subscription before the new one starts, and
-- a handler kept past its activation delivers nothing.
return function(plugin)
  local function rejects(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
  end

  local listeners = {}
  local cancels = 0
  local function subscribe(handler)
    local entry = { handler = handler }
    listeners[#listeners + 1] = entry
    return function()
      local index = table.find(listeners, entry)
      if index then
        table.remove(listeners, index)
        cancels += 1
      end
    end
  end
  local function emit(event)
    for _, entry in ipairs(table.clone(listeners)) do
      entry.handler(event)
    end
  end

  local received = {}
  local definition = plugin.define {
    name = 'definition',
    init = function(context, config)
      context:on(subscribe, function(event)
        received[#received + 1] = config.name .. ':' .. event
      end)
    end,
  }

  local runtime = plugin.runtime()
  local instance = runtime:use(definition, { name = 'one' })
  instance:enable()
  assert(#listeners == 1)
  emit 'a'
  assert(received[1] == 'one:a')

  local kept = listeners[1].handler
  instance:reload { name = 'two' }
  assert(#listeners == 1 and cancels == 1, 'reload replaces the subscription')
  emit 'b'
  assert(#received == 2 and received[2] == 'two:b', 'the old handler is not called after reload')
  kept 'late'
  assert(#received == 2, 'a handler kept past its activation delivers nothing')

  instance:disable()
  assert(#listeners == 0 and cancels == 2, 'disable cancels the subscription')
  emit 'c'
  assert(#received == 2)

  local failing = runtime:use(
    plugin.define {
      name = 'subscriptions-2',
      init = function(context)
        context:on(function()
          return 'not a cancel function'
        end, function() end)
      end,
    },
    {}
  )
  failing:enable()
  assert(failing:state() == 'failed')
  assert(tostring(failing:diagnostic()):find('answers the function that cancels it', 1, true), failing:diagnostic())

  local checked = runtime:use(
    plugin.define {
      name = 'subscriptions-3',
      init = function(context)
        rejects(function()
          context:on(subscribe, 'not a handler')
        end, 'plugin on: a handler is a function, not a string')
        rejects(function()
          context:on('not a subscription', function() end)
        end, 'plugin on: a subscription is a function, not a string')
      end,
    },
    {}
  )
  checked:enable()
  assert(checked:state() == 'active')
  runtime:close()
end
