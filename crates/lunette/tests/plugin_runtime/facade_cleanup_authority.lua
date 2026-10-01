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
  local plugin = require '@lunette-plugin'
  for _, missing in { false, true } do
    local suffix = tostring(missing)
    local dependency = plugin.capability { name = 'audit/facade-cleanup-dependency-' .. suffix, schema = 1 }
    local output = plugin.capability { name = 'audit/facade-cleanup-output-' .. suffix, schema = 1 }
    local runtime = plugin.runtime()
    local events = {}
    local acquired = 0
    local childLoads = 0
    local providerAlive = true
    local provider = plugin.define {
      name = 'provider',
      provides = { service = dependency },
      init = function(context, _, publish)
        context:effect(function()
          return function()
            table.insert(events, 'provider')
            providerAlive = false
          end
        end)
        publish:provide(dependency, 42)
      end,
    }
    runtime:use(provider, {}):enable()
    local child = plugin.define {
      name = 'child',
      init = function()
        childLoads += 1
      end,
    }
    local definition = plugin.define {
      name = 'definition',
      requires = { service = dependency },
      provides = { service = output },
      init = function(context)
        context:effect(function()
          return function()
            assert(providerAlive and context:require(dependency) == 42, 'facade cleanup lost dependency reads')
            table.insert(events, 'inverse')
            assert(not context:active(), 'facade rollback remains active')
            assert(not pcall(function()
              context:effect(function()
                acquired += 1
                return function()
                  acquired -= 1
                end
              end)
            end), 'facade rollback accepts effect')
            assert(not pcall(function()
              context:child(child, {}):enable()
            end), 'facade rollback accepts child')
          end
        end)
        if not missing then
          error 'facade cleanup initializer failure'
        end
      end,
    }
    runtime:use(definition, {}):enable()
    assert(acquired == 0 and childLoads == 0, 'facade rollback ran acquisition body')
    assert(table.concat(events, ',') == 'inverse', 'facade initializer assertions failed')
    runtime:close()
    assert(table.concat(events, ',') == 'inverse,provider' and acquired == 0, 'facade cleanup leak or retry')
  end
end
