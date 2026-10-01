return function()
  local plugin = require '@lunette-plugin'
  local errorDisplay = require '@lunette-plugins/error-display'
  local errorContract = require '@lunette-contracts/error-display'
  local lunette = require '@lunette'

  -- The live onError listeners. nativeError, the real callback boundary, reads
  -- this list; a cancelled subscription leaves it as the native one does.
  subscriptions = {}
  local cancelCount = 0
  local now = 0

  lunette.onError = function(handler)
    subscriptions[#subscriptions + 1] = handler
    local cancelled = false
    return function()
      if not cancelled then
        cancelled = true
        cancelCount += 1
        table.remove(subscriptions, table.find(subscriptions, handler))
      end
    end
  end

  local runtime = plugin.runtime()
  local errorInstance = runtime:use(errorDisplay.definition, {
    clock = function()
      return now
    end,
  })
  errorInstance:enable()

  local service
  local consumerDefinition = plugin.define {
    name = 'consumerDefinition',
    requires = { errorDisplay = errorContract.capability },
    init = function(context)
      service = context:require(errorContract.capability)
    end,
  }
  local consumer = runtime:use(consumerDefinition, {})
  consumer:enable()

  -- The display needs no panels provider.
  local logged = nativeError('callback failed', 'traceback one')
  assert(logged:find('callback failed', 1, true), 'the boundary logs the error: ' .. logged)
  assert(service:count() == 1)
  assert(service:current() == 'callback failed\ntraceback one')

  -- A listener that raises neither stops the display hearing the error nor
  -- stops the boundary logging it.
  local cancelRaising = lunette.onError(function()
    error 'another listener failed'
  end)
  table.insert(subscriptions, 1, table.remove(subscriptions))
  logged = nativeError('second failure', 'traceback two')
  assert(logged:find('second failure', 1, true))
  assert(service:count() == 2 and service:current():find('second failure', 1, true))
  cancelRaising()

  local pass = {
    setColor = function() end,
    plane = function()
      error 'display draw failed'
    end,
    text = function() end,
  }
  assert(not pcall(function()
    service:draw(pass)
  end), 'a draw failure raises to the caller of draw')

  assert(not pcall(function()
    service.BACKGROUND[1] = 1
  end), 'the background is frozen')

  local firstService = service
  consumer:disable()
  errorInstance:disable()
  errorInstance:disable()
  assert(cancelCount == 2 and #subscriptions == 0, 'disabling the display cancels its subscription')
  assert(not pcall(function()
    firstService:count()
  end))

  -- With the display gone, the boundary still logs.
  logged = nativeError('unpresented failure', 'traceback three')
  assert(logged:find('unpresented failure', 1, true), 'native logging is independent of the display')

  errorInstance:enable()
  local freshConsumer = runtime:use(consumerDefinition, {})
  freshConsumer:enable()
  local freshService = service
  assert(freshService:count() == 0)
  nativeError('fresh callback', 'fresh trace')
  assert(freshService:count() == 1)

  local limiter = freshService:newLimiter { window = 5, maxKeys = 2 }
  local first, suppressed = limiter:record('same', 0)
  assert(first and suppressed == 0)
  local second = limiter:record('same', 1)
  assert(not second)
  local third, repeated = limiter:record('same', 5)
  assert(third and repeated == 1)
  limiter:record('one', 6)
  limiter:record('two', 7)
  assert(limiter:suppressedCount 'same' == 0)

  runtime:close()
end
