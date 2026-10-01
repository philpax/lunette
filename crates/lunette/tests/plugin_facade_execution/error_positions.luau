-- An initializer's error reaches the report with its own position and
-- traceback, and a membership error names the contract at the caller.
return function(plugin)
  local declared = plugin.capability { name = 'local/positions-declared', schema = 1 }
  local undeclared = plugin.capability { name = 'local/positions-undeclared', schema = 1 }
  local membership
  local probe = plugin.define {
    name = 'probe',
    requires = { declared = declared },
    init = function(context)
      local ok, message = pcall(function()
        context:require(undeclared)
      end)
      assert(not ok)
      membership = tostring(message)
    end,
  }
  local provider = plugin.define {
    name = 'provider',
    provides = { declared = declared },
    init = function(_context, _config, publish)
      publish:provide(declared, {})
    end,
  }
  local function raiseFromInitializer()
    error 'initializer position failure'
  end
  local failing = plugin.define {
    name = 'failing',
    init = function()
      raiseFromInitializer()
    end,
  }

  local runtime = plugin.runtime()
  runtime:use(provider, {}):enable()
  runtime:use(probe, {}):enable()
  runtime:use(failing, {}):enable()
  return membership
end
