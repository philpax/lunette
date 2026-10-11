local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

test('the layout example runs, and its grid arranges five windows in rows of three', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'examples/layout'
  require 'main'
  lovr.load()
  events.logs = {}
  lovr.update(0.016)
  expect.equal(#events.logs, 0, 'the grid is registered by the first frame')
  expect.equal(lovr.draw(events.pass), false, 'draw does not veto')
  expect.equal(lovr.quit(), false, 'quit does not veto')

  events.saved = nil
  local session = testing.boot(
    desktop.compose {
      patches = {
        { insert = { id = 'grid-layout', definition = require('grid').definition, config = { columns = 3 } } },
      },
      settings = { ['desktop/arrange'] = { layout = 'grid' } },
    },
    { native = native }
  )
  local panels = session:observe(panelsContract.capability).service
  events.windows = {}
  local placed: { panelsContract.Panel } = {}
  for index = 1, 5 do
    events.windows[index] = native.newWindow(100 + index)
    native.emit('onWindowOpened', { window = events.windows[index] })
  end
  for index, window in ipairs(events.windows) do
    placed[index] = assert(panels:forSource(window))
  end
  local cellWidth, cellHeight = placed[1].width + 0.08, placed[1].height + 0.08
  for index, panel in ipairs(placed) do
    local column, row = (index - 1) % 3, (index - 1) // 3
    local x, y, z = panel.pose:getPosition()
    expect.near(x, (column - 1) * cellWidth, 1e-5, 'window ' .. index .. ' in column ' .. column)
    expect.near(y, 1.5 + (0.5 - row) * cellHeight, 1e-5, 'window ' .. index .. ' in row ' .. row)
    expect.near(z, -1.8, 1e-5, 'window ' .. index .. ' on the wall')
  end
  session:close()
end)

return test
