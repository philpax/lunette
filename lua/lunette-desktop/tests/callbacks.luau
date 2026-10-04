-- Callback failures include tracebacks, do not stop later handlers, and remain visible in the error panel.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local frameContract = require '@lunette-contracts/frame'
local surfacesContract = require '@lunette-contracts/surfaces'

local test = testing.suite()

test('a raising handler or offer is reported and the ones after it still run', function()
  local ran, broker = {}, nil
  local raising = plugin.define {
    name = 'raising',
    requires = { frame = frameContract.capability, surfaces = surfacesContract.capability },
    init = function(context)
      local frame = context:require(frameContract.capability)
      broker = context:require(surfacesContract.capability)
      local function fails(message)
        return function()
          error(message)
        end
      end
      frame:onUpdate(context, { phase = 'scene', run = fails 'fixture update failure' })
      frame:onUpdate(context, {
        phase = 'scene',
        order = 1,
        run = function()
          ran.update = true
        end,
      })
      frame:onDraw(context, { phase = 'scene', run = fails 'fixture draw failure' })
      frame:onKey(context, { run = fails 'fixture key failure' })
      frame:onKey(context, {
        phase = 'delivery',
        run = function(event)
          ran.key = event.key
        end,
      })
      broker:offer(context, { name = 'raising', list = fails 'fixture surfaces failure' })
      broker:offer(context, {
        name = 'not-a-list',
        list = function()
          return 'not a list'
        end,
      })
      frame:onQuit(context, { run = fails 'fixture quit failure' })
      frame:onQuit(context, {
        run = function()
          ran.quit = true
        end,
      })
    end,
  }
  local session = testing.boot {
    'frame',
    'surfaces',
    'errors',
    { id = 'raising', definition = raising },
    'desktop/errors',
  }
  local events = session.native.events
  local function reported(text)
    local last = events.reported[#events.reported]
    return last ~= nil and last.message:find(text, 1, true) ~= nil and last.traceback ~= ''
  end

  session:update()
  expect.truthy(ran.update, 'a raising update handler does not stop the next')
  expect.equal(#events.reported, 1, 'the update failure is reported')
  expect.truthy(reported 'lovr.update: ' and reported 'fixture update failure', events.reported[1].message)

  expect.equal(session:draw(), false, 'a raising draw handler does not veto the draw')
  expect.truthy(reported 'lovr.draw: ' and reported 'fixture draw failure', 'the draw failure is reported')
  local drawn = {}
  for _, call in ipairs(events.draw) do
    if call[1] == 'text' then
      drawn[#drawn + 1] = tostring(call[2])
    end
  end
  expect.truthy(
    table.concat(drawn, ' '):find('fixture draw failure', 1, true),
    'the error panel draws after a raising draw handler, and shows its error'
  )

  lovr.keypressed('a', 4, false)
  expect.truthy(reported 'lovr.keypressed: ' and reported 'fixture key failure', 'the key failure is reported')
  expect.equal(ran.key, 'a', 'a raising key handler does not consume the key')

  local count = #events.reported
  expect.equal(#broker:all(), 0, 'neither offer lists a surface')
  expect.equal(#events.reported, count + 2, 'both offers are reported')
  expect.truthy(events.reported[count + 1].message:find('surfaces: raising: ', 1, true), 'the raising offer')
  expect.truthy(reported 'surfaces: not-a-list: ' and reported 'not a list of surfaces', 'the offer of no list')

  expect.equal(session:quit(), false, 'a raising quit handler does not veto the quit')
  expect.truthy(ran.quit, 'a raising quit handler does not stop the next')
  expect.truthy(reported 'lovr.quit: ' and reported 'fixture quit failure', 'the quit failure is reported')
  session:close()
end)

return test
