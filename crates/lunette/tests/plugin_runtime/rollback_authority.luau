-- A failed load rolls back with its resource authority revoked before any
-- inverse runs, and keeps the dependency reads the inverses need. Each case runs
-- through the native API and through the facade, which cannot publish a record
-- with an unexpected field and so has no `extra` case.
return function(native, sources)
  local cache = { ['@lunette'] = { plugin = native } }
  require = function(name)
    if cache[name] ~= nil then
      return cache[name]
    end
    local source = assert(sources[name], 'unknown module ' .. name)
    local module = assert(loadstring(source, name))()
    cache[name] = module
    return module
  end
  local facade = require '@lunette-plugin'

  -- Each API defines from `{ requires, provides, init(context, provide) }`,
  -- where `provide(key, value)` publishes under a provision's key.
  local apis = {
    native = {
      reasons = { 'initializer', 'missing', 'extra' },
      capability = function(name)
        return native.contract(name, 1)
      end,
      define = function(spec)
        return native.define(spec.requires, spec.provides, function(context)
          local record = {}
          spec.init(context, function(key, value)
            record[key] = value
          end)
          return record
        end)
      end,
      read = function(context, key)
        return context:services()[key]
      end,
    },
    facade = {
      reasons = { 'initializer', 'missing' },
      capability = function(name)
        return facade.capability { name = name, schema = 1 }
      end,
      define = function(spec)
        return facade.define {
          name = 'rollback',
          requires = spec.requires,
          provides = spec.provides,
          init = function(context, _config, publish)
            spec.init(context, function(key, value)
              publish:provide(spec.provides[key], value)
            end)
          end,
        }
      end,
      read = function(context, key, capability)
        return context:require(capability)
      end,
    },
  }

  for _, via in { 'native', 'facade' } do
    local api = apis[via]
    for _, reason in api.reasons do
      for _, broken in { false, true } do
        local runtime = if via == 'native' then native.runtime() else facade.runtime()
        local suffix = via .. '-' .. reason .. '-' .. tostring(broken)
        local dependency = api.capability('audit/rollback-dependency-' .. suffix)
        local output = api.capability('audit/rollback-output-' .. suffix)
        local childToken = api.capability('audit/rollback-child-' .. suffix)
        local events = {}
        local providerAlive = true
        local providerLoads = 0
        local providerContext
        local providerDefinition = api.define {
          requires = {},
          provides = { service = dependency },
          init = function(context, provide)
            providerLoads += 1
            providerContext = context
            context:effect(function()
              return function()
                table.insert(events, 'provider')
                providerAlive = false
              end
            end)
            provide('service', 42)
          end,
        }
        local provider = runtime:use(providerDefinition, {})
        provider:enable()
        local childLoads = 0
        local childDefinition = api.define {
          requires = {},
          provides = { service = childToken },
          init = function(_context, provide)
            childLoads += 1
            provide('service', {})
          end,
        }
        local acquired = 0
        local loads = 0
        local escaped
        local attempts = {}
        local definition = api.define {
          requires = { dependency = dependency },
          provides = { service = output },
          init = function(context, provide)
            loads += 1
            escaped = context
            for ordinal = 1, 3 do
              local index = ordinal
              context:effect(function()
                return function()
                  table.insert(events, tostring(index))
                  assert(
                    providerAlive and api.read(context, 'dependency', dependency) == 42,
                    'rollback lost dependency read authority'
                  )
                  attempts[index] = {
                    active = context:active(),
                    effect = pcall(function()
                      context:effect(function()
                        acquired += 1
                        return function()
                          acquired -= 1
                        end
                      end)
                    end),
                    child = pcall(function()
                      context:child(childDefinition, {}):enable()
                    end),
                    owner = pcall(function()
                      providerContext:checkOwner(context)
                    end),
                  }
                  if broken and index == 2 then
                    error 'rollback authority inverse failure'
                  end
                end
              end)
            end
            if reason == 'initializer' then
              error 'rollback authority initializer failure'
            elseif reason == 'extra' then
              provide('service', {})
              provide('unexpected', true)
            end
          end,
        }
        local instance = runtime:use(definition, {})
        instance:enable()
        assert(table.concat(events, ',') == '3,2,1', 'rollback must attempt remaining inverses in reverse order')
        assert(acquired == 0, 'rollback inverse ran a new acquisition body')
        for index = 1, 3 do
          local attempt = attempts[index]
          assert(attempt ~= nil, 'rollback inverse skipped')
          assert(
            not attempt.active and not attempt.effect and not attempt.child and not attempt.owner,
            'rollback context retains resource authority'
          )
        end
        assert(childLoads == 0, 'rollback installed an activatable child')
        assert(not escaped:active() and not pcall(function()
          escaped:effect(function()
            acquired += 1
            return function() end
          end)
        end), 'completed rollback context remains usable')
        if broken then
          assert(instance:state() == 'quarantined', 'failed rollback was not quarantined')
          provider:disable()
          provider:reload {}
          provider:enable()
          assert(not pcall(function()
            instance:enable()
          end), 'quarantined instance accepted enable')
          assert(not pcall(function()
            instance:reload {}
          end), 'quarantined instance accepted reload')
          instance:dispose()
          runtime:drain()
          assert(loads == 1, 'failed rollback was retried')
          assert(providerLoads == 2, 'quarantine pinned its dependency')
          local duplicate = runtime:use(definition, {})
          assert(not pcall(function()
            duplicate:enable()
          end), 'failed rollback released its reservation')
        end
        assert(
          pcall(function()
            runtime:use(childDefinition, {})
          end),
          'rollback child attempt reserved a contract'
        )
        runtime:close()
        local expected = if broken then '3,2,1,provider,provider' else '3,2,1,provider'
        assert(
          table.concat(events, ',') == expected,
          'shutdown retried rollback or released dependencies out of order: ' .. table.concat(events, ',')
        )
        assert(acquired == 0 and childLoads == 0, 'rollback resource leaked after close')
      end
    end
  end
end
