-- Each malformed definition or capability spec is rejected at the caller with
-- a message that names the problem. The messages are returned in order.
return function(plugin)
  local messages = {}
  local function capture(attempt)
    local ok, message = pcall(attempt)
    assert(not ok, 'a malformed spec was accepted')
    messages[#messages + 1] = tostring(message)
  end
  local function init() end

  capture(function()
    plugin.define { name = 'typo', require = {}, init = init }
  end)
  capture(function()
    plugin.define { init = init }
  end)
  capture(function()
    plugin.define { name = '', init = init }
  end)
  capture(function()
    plugin.define { name = 'no-init' }
  end)
  capture(function()
    plugin.define { name = 'bad-requires', requires = 'panels', init = init }
  end)
  capture(function()
    plugin.define { name = 'bad-provides', provides = 42, init = init }
  end)
  capture(function()
    plugin.define(init)
  end)
  capture(function()
    plugin.capability { name = 'local/typo', schema = 1, witness = init }
  end)
  capture(function()
    plugin.capability { schema = 1 }
  end)
  capture(function()
    plugin.capability { name = '', schema = 1 }
  end)
  capture(function()
    plugin.capability { name = 'local/fractional', schema = 1.5 }
  end)
  capture(function()
    plugin.capability { name = 'local/zero', schema = 0 }
  end)
  capture(function()
    plugin.capability { name = 'local/missing-schema' }
  end)

  local named = plugin.define { name = 'named', init = init }
  assert(named.name == 'named')
  assert(next(named.requires) == nil and next(named.provides) == nil)
  return messages
end
