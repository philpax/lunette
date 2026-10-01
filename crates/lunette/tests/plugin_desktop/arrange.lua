-- The arrangement of adopted windows in the shipped composition: a window the
-- user drops leaves the arranged set, so closing another window does not
-- snap it back.
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'

local desktop = require 'fixture/graph'()
local service, owner
desktop.runtime
  :use(
    plugin.define {
      name = 'arrange-probe',
      requires = { panels = panels.capability },
      init = function(context)
        service, owner = context:require(panels.capability), context
      end,
    },
    {}
  )
  :enable()

local function position(panel)
  local x, y, z = panel.pose:getPosition()
  return x, y, z
end

local first, second, third = newWindow(1), newWindow(2), newWindow(3)
events.windows = { first, second, third }
for _, window in ipairs(events.windows) do
  emit('onWindowOpened', { window = window })
end
local dragged = assert(service:forSource(first))
local _, arcY = position(dragged)
assert(arcY == 1.5, 'an adopted window is arranged on the arc')

-- The user drags the first window away and drops it.
dragged:setPose(lovr.math.newMat4():translate(3, 2, -4))
service:emitDropped(owner, dragged, {})

-- Another window closes, and the remaining ones are arranged again.
second.dead = true
events.windows = { first, third }
emit('onWindowClosed', { window = second })
lovr.update(0.016)
local x, y, z = position(dragged)
assert(x == 3 and y == 2 and z == -4, 'a dropped window keeps where it was dropped: ' .. x .. ' ' .. y .. ' ' .. z)
local remaining = assert(service:forSource(third))
local rx, ry, rz = position(remaining)
assert(rx == 0 and ry == 1.5 and rz == -1.6, 'the one window left in the arrangement is centred')
assert(lovr.quit() == false)
