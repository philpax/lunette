-- An initializer's error reaches the report with its own position and
-- traceback, and a membership error names the contract at the caller.
return function(plugin)
  local function identity(value)
    return value
  end

  local declared = plugin.capability('local/positions-declared', 1, identity)
  local undeclared = plugin.capability('local/positions-undeclared', 1, identity)
  local membership
  local probe = plugin.define(identity, { declared = declared }, {}, function(context)
    local ok, message = pcall(function()
      context:require(undeclared)
    end)
    assert(not ok)
    membership = tostring(message)
  end)
  local provider = plugin.define(identity, {}, { declared = declared }, function(_context, _config, publish)
    publish:provide(declared, {})
  end)
  local function raiseFromInitializer()
    error 'initializer position failure'
  end
  local failing = plugin.define(identity, {}, {}, function()
    raiseFromInitializer()
  end)

  local runtime = plugin.runtime()
  runtime:use(provider, {}):enable()
  runtime:use(probe, {}):enable()
  runtime:use(failing, {}):enable()
  return membership
end
