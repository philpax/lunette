-- The layout example in examples/layout: its main.luau starts the shipped
-- desktop with the grid and follow-me layouts inserted and the grid chosen.
-- The grid arranges adopted windows in rows and columns and leaves a dropped
-- one where it was dropped; the follow-me layout, chosen by a patch, turns
-- with the head on every frame.
require 'main'
lovr.load()
events.logs = {}
lovr.update(0.016)
assert(
  #events.logs == 0,
  'the grid is registered by the first frame: ' .. tostring(events.logs[1] and events.logs[1][1])
)
assert(lovr.draw(events.pass) == false)
assert(package.loaded['./grid'].name == 'grid-layout', 'main.luau inserts the grid')
assert(lovr.quit() == false)

local plugin = require '@lunette-plugin'
local panelsContract = require '@lunette-contracts/panels'

-- Each run starts with no windows and no saved arrangement: a quit saves one,
-- and a window placed from it is not arranged.
local function started(layout, options)
  events.windows = {}
  events.saved = nil
  local desktop = require 'fixture/graph' {
    patches = {
      { insert = { id = 'grid-layout', definition = require './grid' } },
      { insert = { id = 'follow-layout', definition = require './follow' } },
      { id = 'desktop/arrange', config = { layout = layout, options = options } },
    },
  }
  for id, instance in pairs(desktop.instances) do
    assert(instance:state() == 'active', id .. ': ' .. tostring(instance:diagnostic()))
  end
  local owner
  desktop.runtime
    :use(
      plugin.define {
        name = 'example-probe',
        requires = { panels = panelsContract.capability },
        init = function(context)
          owner = context
        end,
      },
      {}
    )
    :enable()
  return desktop, owner
end

local function open(count)
  events.windows = {}
  for index = 1, count do
    local window = newWindow(100 + index)
    events.windows[index] = window
    emit('onWindowOpened', { window = window })
  end
end

local function position(panel)
  local x, y, z = panel.pose:getPosition()
  return x, y, z
end

local function near(a, b)
  return math.abs(a - b) < 1e-9
end

-- Five windows in three columns: two rows, the first full, on the wall.
local desktop, owner = started('grid', { grid = { columns = 3 } })
open(5)
local placed = {}
for index, window in ipairs(events.windows) do
  placed[index] = assert(desktop.panels:forSource(window))
end
local cellWidth = placed[1].width + 0.08
local cellHeight = placed[1].height + 0.08
for index, panel in ipairs(placed) do
  local column, row = (index - 1) % 3, (index - 1) // 3
  local x, y, z = position(panel)
  assert(near(x, (column - 1) * cellWidth), 'window ' .. index .. ' is in column ' .. column .. ': ' .. x)
  assert(near(y, 1.5 + (0.5 - row) * cellHeight), 'window ' .. index .. ' is in row ' .. row .. ': ' .. y)
  assert(z == -1.8)
end

-- A window dropped elsewhere leaves the grid; the others close up when one
-- closes, and the dropped one stays.
placed[2]:setPose(lovr.math.newMat4():translate(4, 1, -3))
desktop.drop(placed[2])
events.windows[5].dead = true
emit('onWindowClosed', { window = events.windows[5] })
lovr.update(0.016)
local x, y = position(placed[2])
assert(x == 4 and y == 1, 'the dropped window stays where it was dropped')
x, y = position(placed[3])
assert(near(x, 0) and near(y, 1.5), 'three windows make one row, and the third moves into its middle cell')
assert(lovr.quit() == false)

-- An option the grid does not take is the grid's to reject. The grid is
-- inserted after the arranging consumer, so the arrangement that meets it is
-- the one made when the grid registers, and its error is reported, naming
-- the option.
events.reported = {}
events.windows = {}
events.saved = nil
require 'fixture/graph' {
  patches = {
    { insert = { id = 'grid-layout', definition = require './grid' } },
    { id = 'desktop/arrange', config = { layout = 'grid', options = { grid = { colums = 3 } } } },
  },
}
open(1)
local found = false
for _, report in ipairs(events.reported) do
  found = found or report.message:find('plugin grid: unknown option colums', 1, true) ~= nil
end
assert(found, 'the misspelt option is reported')
assert(lovr.quit() == false)

-- The follow-me layout is continuous: each frame places the windows around
-- the head, so they move with it without any window being placed or closed.
desktop = started 'follow'
open(1)
local followed = assert(desktop.panels:forSource(events.windows[1]))
lovr.update(0.016)
local fx, fy, fz = position(followed)
assert(near(fx, 0) and fy == 1.5 and near(fz, -1.4), 'the window is ahead of the head: ' .. fx .. ' ' .. fz)
events.handX = 1
lovr.update(0.016)
fx = position(followed)
assert(near(fx, 1), 'the window follows the head: ' .. fx)
events.handX = nil
assert(lovr.quit() == false)
