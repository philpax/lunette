-- An owner is checked by the identity of the context the adapter wrapped, not
-- by any field a caller can copy into a table of its own.
return function(plugin)
  local function identity(value)
    return value
  end

  local guarded = plugin.capability { name = 'local/guarded', schema = 1 }
  local checked = false
  local provider = plugin.define {
    name = 'provider',
    provides = { guarded = guarded },
    init = function(context, _config, publish)
      publish:provide(guarded, {
        touch = function(_self, owner)
          context:checkOwner(owner)
          return true
        end,
      })
    end,
  }
  local consumer = plugin.define {
    name = 'consumer',
    requires = { guarded = guarded },
    init = function(context)
      local service = context:require(guarded)
      assert(service:touch(context), 'a genuine owner was rejected')
      local forged = setmetatable({}, { __index = context })
      local ok, message = pcall(function()
        service:touch(forged)
      end)
      assert(not ok and string.find(tostring(message), 'not a plugin context', 1, true), tostring(message))
      checked = true
    end,
  }

  local runtime = plugin.runtime()
  runtime:use(provider, {}):enable()
  runtime:use(consumer, {}):enable()
  assert(checked, 'the consumer did not load')
  runtime:close()
end
