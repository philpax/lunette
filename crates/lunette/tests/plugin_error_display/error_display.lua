return function()
  local plugin = require '@lunette-plugin'
  local panelsDefinition = require '@lunette-plugins/panels'
  local errorDisplay = require '@lunette-plugins/error-display'
  local panelsContract = require '@lunette-contracts/panels'
  local errorContract = require '@lunette-contracts/error-display'
  local lunette = require '@lunette'

  local subscriptions = {}
  local cancelCount = 0
  local nativeLogCount = 0
  local now = 0

  lunette.onError = function(handler)
    subscriptions[#subscriptions + 1] = handler
    local cancelled = false
    return function()
      if not cancelled then
        cancelled = true
        cancelCount += 1
      end
    end
  end

  local function nativeError(message, traceback)
    nativeLogCount += 1
    local listeners = table.clone(subscriptions)
    for _, listener in ipairs(listeners) do
      local ok = pcall(listener, { message = message, traceback = traceback })
      if not ok then
        nativeLogCount += 1
      end
    end
  end

  local runtime = plugin.runtime()
  local panelsInstance = runtime:use(panelsDefinition, {})
  local errorInstance = runtime:use(errorDisplay.definition, {
    clock = function()
      return now
    end,
  })
  panelsInstance:enable()
  errorInstance:enable()

  local service
  local consumerDefinition = plugin.define(function(config)
    return config
  end, {
    panels = panelsContract.capability,
    errorDisplay = errorContract.capability,
  }, {}, function(context)
    service = context:require(errorContract.capability)
  end)
  local consumer = runtime:use(consumerDefinition, {})
  consumer:enable()

  nativeError('callback failed', 'traceback one')
  assert(nativeLogCount == 1)
  assert(service:count() == 1)
  assert(service:current() == 'callback failed\ntraceback one')

  local pass = {
    setColor = function() end,
    plane = function()
      error 'display draw failed'
    end,
    text = function() end,
  }
  local drawOk = pcall(function()
    service:draw(pass)
  end)
  assert(not drawOk)
  assert(nativeLogCount == 1)

  local firstSubscription = subscriptions[1]
  local firstService = service
  consumer:disable()
  errorInstance:disable()
  errorInstance:disable()
  assert(cancelCount == 1)
  firstSubscription { message = 'stale callback', traceback = 'stale trace' }
  assert(not pcall(function()
    firstService:count()
  end))

  errorInstance:enable()
  local freshConsumer = runtime:use(consumerDefinition, {})
  freshConsumer:enable()
  local freshService = service
  firstSubscription { message = 'stale callback', traceback = 'stale trace' }
  assert(freshService:count() == 0)
  nativeError('fresh callback', 'fresh trace')
  assert(nativeLogCount == 2)
  assert(freshService:count() == 1)

  local limiter = freshService:newLimiter(5, 2)
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
