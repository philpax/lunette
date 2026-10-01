-- A consumer reads a provision through a frozen view. The view raises once the
-- provider's activation has ended, even for a reference the consumer kept, and
-- it raises on every write.
return function(plugin)
  local function identity(value)
    return value
  end

  local function rejects(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
    return tostring(message)
  end

  local counter = plugin.capability('local/revocation-counter', 1, identity)
  local doubler = plugin.capability('local/revocation-doubler', 1, identity)
  local kept
  local keptDoubler
  local seen = {}

  local provider = plugin.define(
    identity,
    {},
    { counter = counter, doubler = doubler },
    function(_context, _config, publish)
      local count = 0
      local service = { LIMIT = 3 }
      function service.bump(self, by)
        count += by
        return self.LIMIT, count
      end
      function service.refuse(_self)
        error('the bump is refused', 2)
      end
      publish:provide(counter, service)
      publish:provide(
        doubler,
        setmetatable({}, {
          __call = function(_self, value)
            return value * 2
          end,
        })
      )
    end
  )
  local consumer = plugin.define(identity, { counter = counter, doubler = doubler }, {}, function(context, config)
    seen[config.name] = context:require(counter)
    kept = seen[config.name]
    keptDoubler = context:require(doubler)
  end)

  local runtime = plugin.runtime()
  local providerInstance = runtime:use(provider, {})
  providerInstance:enable()
  runtime:use(consumer, { name = 'first' }):enable()
  runtime:use(consumer, { name = 'second' }):enable()

  assert(rawequal(seen.first, seen.second), 'consumers of one generation share its view')
  local limit, count = kept:bump(2)
  assert(limit == 3 and count == 2, 'a method receives the view as self')
  assert(keptDoubler(21) == 42, 'a callable provision stays callable')
  local fields = {}
  for key in kept do
    fields[key] = true
  end
  assert(fields.LIMIT and fields.bump, 'the view iterates the provision')

  local refused = rejects(function()
    kept:refuse()
  end, 'the bump is refused')
  assert(refused:find('revocation', 1, true) and not refused:find('adapter', 1, true), refused)

  rejects(function()
    kept.LIMIT = 4
  end, 'capability local/revocation-counter@1 is read-only, so LIMIT cannot be assigned')
  rejects(function()
    kept.extra = true
  end, 'is read-only')
  rejects(function()
    setmetatable(kept, nil)
  end, 'readonly')
  assert(kept.LIMIT == 3 and kept.extra == nil)

  local stale = kept
  local staleDoubler = keptDoubler
  local method = stale.bump
  providerInstance:disable()
  local revoked =
    'capability local/revocation-counter@1 is no longer available because its provider activation has ended'
  local message = rejects(function()
    stale:bump(1)
  end, revoked)
  assert(message:find('revocation', 1, true), 'a revoked read names the consumer: ' .. message)
  rejects(function()
    return stale.LIMIT
  end, revoked)
  rejects(function()
    for _ in stale do
    end
  end, revoked)
  rejects(function()
    staleDoubler(1)
  end, 'local/revocation-doubler@1 is no longer available')

  -- A method read before revocation is a value like any other read. The view
  -- guards reads, not the provider state that a kept function closes over.
  assert(type(method) == 'function')

  providerInstance:enable()
  assert(not rawequal(kept, stale), 'a new provider generation publishes a new view')
  assert(select(2, kept:bump(1)) == 1, 'the new generation serves its consumers')
  rejects(function()
    stale:bump(1)
  end, revoked)
  runtime:close()
end
