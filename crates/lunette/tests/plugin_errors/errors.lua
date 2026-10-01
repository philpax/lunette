return function()
  local plugin = require '@lunette-plugin'
  local errorStream = require '@lunette-plugins/errors'
  local errorContract = require '@lunette-contracts/errors'
  local limiter = require '@lunette-plugins/errors/limiter'
  local format = require '@lunette-plugins/errors/format'
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
  -- A subscriber's error is reported through the native boundary, which
  -- notifies the stream again.
  lunette.reportError = function(fields)
    nativeError(fields.context .. ': ' .. fields.message, fields.traceback or '')
  end

  local runtime = plugin.runtime()
  local streamInstance = runtime:use(errorStream.definition, {
    history = 3,
    clock = function()
      return now
    end,
  })
  streamInstance:enable()

  local service, owner
  local heard, cleared = {}, 0
  local consumerDefinition = plugin.define {
    name = 'presenter',
    requires = { errors = errorContract.capability },
    init = function(context)
      service, owner = context:require(errorContract.capability), context
      service:subscribe(context, {
        run = function(report)
          heard[#heard + 1] = report
        end,
        cleared = function()
          cleared += 1
        end,
      })
    end,
  }
  local consumer = runtime:use(consumerDefinition, {})
  consumer:enable()

  -- A report reaches every subscriber with its text and sequence.
  local logged = nativeError('callback failed', 'traceback one')
  assert(logged:find('callback failed', 1, true), 'the boundary logs the error: ' .. logged)
  assert(#heard == 1 and heard[1].sequence == 1 and heard[1].suppressed == 0)
  assert(heard[1].text == 'callback failed\ntraceback one')
  assert(not pcall(function()
    heard[1].text = 'changed'
  end), 'a report is frozen')

  -- A repeat within the window is withheld and counted on the next delivery.
  nativeError('callback failed', 'traceback one')
  assert(#heard == 1, 'a repeat within the window is withheld')
  now = 6
  nativeError('callback failed', 'traceback one')
  assert(#heard == 2 and heard[2].suppressed == 1 and heard[2].text:find('1 identical error was suppressed', 1, true))

  -- A listener that raises neither stops the stream hearing the error nor
  -- stops the boundary logging it.
  local cancelRaising = lunette.onError(function()
    error 'another listener failed'
  end)
  table.insert(subscriptions, 1, table.remove(subscriptions))
  logged = nativeError('second failure', 'traceback two')
  assert(logged:find('second failure', 1, true))
  assert(#heard == 3 and heard[3].message == 'second failure')
  cancelRaising()

  -- The history is bounded and oldest first.
  nativeError('third failure', 'traceback three')
  local recent = service:recent()
  assert(#recent == 3 and recent[1].sequence == 2 and recent[3].message == 'third failure', 'the bounded history')

  -- A subscriber that raises is reported, and its own report joins the
  -- history without being delivered again.
  local raising = runtime:use(
    plugin.define {
      name = 'raising-presenter',
      requires = { errors = errorContract.capability },
      init = function(context)
        context:require(errorContract.capability):subscribe(context, {
          run = function()
            error 'presenter failure'
          end,
        })
      end,
    },
    {}
  )
  raising:enable()
  local before = #heard
  nativeError('fourth failure', 'traceback four')
  assert(#heard == before + 1, 'the other subscriber still hears the report')
  recent = service:recent()
  assert(recent[#recent].message:find('presenter failure', 1, true), 'the subscriber failure joins the history')
  raising:dispose()

  -- clear forgets the history and tells every subscriber.
  service:clear(owner)
  assert(#service:recent() == 0 and cleared == 1)
  now = 20
  nativeError('after clearing', 'traceback five')
  assert(heard[#heard].sequence == 1, 'the sequence restarts after a clear')

  for _, malformed in ipairs {
    'run',
    { run = 'presenter' },
    { run = function() end, cleared = 3 },
    { run = function() end, colour = true },
  } do
    assert(not pcall(function()
      service:subscribe(owner, malformed)
    end), 'a malformed subscriber raises')
  end

  local firstService = service
  consumer:disable()
  streamInstance:disable()
  streamInstance:disable()
  assert(cancelCount == 2 and #subscriptions == 0, 'disabling the stream cancels its subscription')
  assert(not pcall(function()
    firstService:recent()
  end))

  -- With the stream gone, the boundary still logs.
  logged = nativeError('unpresented failure', 'traceback six')
  assert(logged:find('unpresented failure', 1, true), 'native logging is independent of the stream')

  streamInstance:enable()
  local before = #heard
  local freshConsumer = runtime:use(consumerDefinition, {})
  freshConsumer:enable()
  assert(#service:recent() == 0, 'a new activation starts with an empty history')
  nativeError('fresh callback', 'fresh trace')
  assert(#heard == before + 1 and heard[#heard].sequence == 1)

  -- The pure halves.
  local limit = limiter.new(5, 2)
  local first, suppressed = limit:record('same', 0)
  assert(first and suppressed == 0)
  local second = limit:record('same', 1)
  assert(not second)
  local third, repeated = limit:record('same', 5)
  assert(third and repeated == 1)
  limit:record('one', 6)
  limit:record('two', 7)
  assert(limit:suppressedCount 'same' == 0)
  assert(format.key { message = 'm', traceback = 't' } == 'm\nt')
  local lines = format.lines({ latest = 'a b c d e f', count = 2 }, { columns = 3, lines = 2 })
  assert(lines[1]:find('(2 so far)', 1, true) and #lines == 3 and lines[3] == '…')

  -- Malformed options fail the activation and are reported.
  for _, config in ipairs { { history = 0 }, { window = -1 }, { maxKeys = 1.5 } } do
    local bad = runtime:use(errorStream.definition, config)
    streamInstance:disable()
    bad:enable()
    assert(bad:state() ~= 'active', 'a malformed option fails the activation')
    bad:dispose()
    streamInstance:enable()
  end

  runtime:close()
end
