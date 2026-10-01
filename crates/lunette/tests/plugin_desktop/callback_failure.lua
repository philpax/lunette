local plugin = require '@lunette-plugin'
local callbacks = require 'desktop/callbacks'
local runtime = plugin.runtime()
callbacks.install(function() end, function()
  runtime:close()
end)
runtime:use(require('@lunette-plugins/error-display').definition, {}):enable()
local ran = {}
runtime
  :use(
    plugin.define(function(config)
      return config
    end, {}, {}, function(ctx)
      callbacks.onUpdate(ctx, function()
        error 'fixture update failure'
      end, 1)
      callbacks.onUpdate(ctx, function()
        ran.update = true
      end, 2)
      callbacks.onDraw(ctx, function()
        error 'fixture draw failure'
      end, 1)
      callbacks.onSurfaces(ctx, function()
        error 'fixture surfaces failure'
      end)
      callbacks.onQuit(ctx, function()
        error 'fixture quit failure'
      end)
      callbacks.onQuit(ctx, function()
        ran.quit = true
      end)
    end),
    {}
  )
  :enable()
runtime:use(require 'desktop/errors', { callbacks = callbacks }):enable()

local function reported(text)
  local last = events.reported[#events.reported]
  return last ~= nil and last.message:find(text, 1, true) ~= nil and last.traceback ~= ''
end

lovr.update(0)
assert(ran.update, 'a raising update handler does not stop the next')
assert(#events.reported == 1 and reported 'lovr.update: ' and reported 'fixture update failure')

events.draw = {}
assert(lovr.draw(events.pass) == false)
assert(reported 'lovr.draw: ' and reported 'fixture draw failure')
local drawn = {}
for _, call in ipairs(events.draw) do
  if call[1] == 'text' then
    drawn[#drawn + 1] = tostring(call[2])
  end
end
assert(
  table.concat(drawn, ' '):find('fixture draw failure', 1, true),
  'the error display still draws after a raising draw handler, and shows its error'
)

assert(#callbacks.surfaces() == 0)
assert(reported 'lovr.surfaces: ' and reported 'fixture surfaces failure')

assert(lovr.quit() == false, 'a raising quit handler does not veto the quit')
assert(ran.quit, 'a raising quit handler does not stop the next')
assert(reported 'lovr.quit: ' and reported 'fixture quit failure')
lovr.update(0)
