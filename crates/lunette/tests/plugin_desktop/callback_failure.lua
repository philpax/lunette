-- A raising frame handler or surface offer is reported and does not stop the
-- handlers after it, including the error display that would show it.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-plugins/frame'
local frameContract = require '@lunette-contracts/frame'
local surfacesContract = require '@lunette-contracts/surfaces'
local runtime = plugin.runtime()
frame.install {
  start = function() end,
  stop = function()
    runtime:close()
  end,
}
runtime:use(frame.definition, {}):enable()
runtime:use(require('@lunette-plugins/surfaces').definition, {}):enable()
runtime:use(require('@lunette-plugins/errors').definition, {}):enable()
local ran = {}
local broker
runtime
  :use(
    plugin.define {
      name = 'callback-failure-1',
      requires = { frame = frameContract.capability, surfaces = surfacesContract.capability },
      init = function(ctx)
        local frameService = ctx:require(frameContract.capability)
        broker = ctx:require(surfacesContract.capability)
        frameService:onUpdate(ctx, {
          phase = 'scene',
          run = function()
            error 'fixture update failure'
          end,
        })
        frameService:onUpdate(ctx, {
          phase = 'scene',
          order = 1,
          run = function()
            ran.update = true
          end,
        })
        frameService:onDraw(ctx, {
          phase = 'scene',
          run = function()
            error 'fixture draw failure'
          end,
        })
        frameService:onKey(ctx, {
          run = function()
            error 'fixture key failure'
          end,
        })
        frameService:onKey(ctx, {
          phase = 'delivery',
          run = function(event)
            ran.key = event.key
          end,
        })
        broker:offer(ctx, {
          name = 'raising',
          list = function()
            error 'fixture surfaces failure'
          end,
        })
        broker:offer(ctx, {
          name = 'not-a-list',
          list = function()
            return 'not a list'
          end,
        })
        frameService:onQuit(ctx, {
          run = function()
            error 'fixture quit failure'
          end,
        })
        frameService:onQuit(ctx, {
          run = function()
            ran.quit = true
          end,
        })
      end,
    },
    {}
  )
  :enable()
runtime:use(require '@lunette-desktop/errors', {}):enable()

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

lovr.keypressed('a', 4, false)
assert(reported 'lovr.keypressed: ' and reported 'fixture key failure')
assert(ran.key == 'a', 'a raising key handler does not consume the key')

local count = #events.reported
assert(#broker:all() == 0)
assert(#events.reported == count + 2)
assert(events.reported[count + 1].message:find('surfaces: raising: ', 1, true))
assert(events.reported[count + 1].message:find('fixture surfaces failure', 1, true))
assert(reported 'surfaces: not-a-list: ' and reported 'not a list of surfaces')

assert(lovr.quit() == false, 'a raising quit handler does not veto the quit')
assert(ran.quit, 'a raising quit handler does not stop the next')
assert(reported 'lovr.quit: ' and reported 'fixture quit failure')
lovr.update(0)
