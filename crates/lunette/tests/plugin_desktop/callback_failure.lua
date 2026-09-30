local plugin = require '@lunette-plugin'
local callbacks = require 'desktop/callbacks'
local runtime = plugin.runtime()
callbacks.install(function() end, function()
  runtime:close()
end)
local instance = runtime:use(
  plugin.define(function(config)
    return config
  end, {}, {}, function(ctx)
    callbacks.onUpdate(ctx, function()
      error 'fixture callback failure'
    end)
    callbacks.onQuit(ctx, function()
      error 'fixture quit failure'
    end)
  end),
  {}
)
instance:enable()
local ok, message = pcall(lovr.update, 0)
assert(not ok and tostring(message):find('fixture callback failure', 1, true), 'callback failures remain visible')
assert(lovr.quit() == false)
assert(#events.logs == 1 and events.logs[1][1]:find('fixture quit failure', 1, true))
lovr.update(0)
