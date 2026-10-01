-- Output scale: each output steps with hysteresis by its nearest shown panel,
-- a hidden panel gives no distance, unloading restores the scale an output
-- had, and a desktop without the entry sets no scale.
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'

local owner
local probe = plugin.define {
  name = 'scale-probe',
  requires = { panels = panels.capability },
  init = function(context)
    owner = context
  end,
}
local desktop = require 'fixture/graph' { patches = { { insert = { id = 'probe', definition = probe } } } }

local function frame()
  lovr.update(0.016)
end
-- The fixture's head is at (0, 1.5, 0), so a panel `distance` metres straight
-- ahead of it is that far away.
local function place(source, distance)
  assert(desktop.panels:forSource(source)):setPose(lovr.math.newMat4(0, 1.5, -distance))
end
local function modesOf(output)
  local found = {}
  for _, mode in ipairs(events.modes) do
    if mode.output == output.id then
      found[#found + 1] = mode.scale
    end
  end
  return found
end

local primary, secondary = events.outputs[1], newOutput(2, 1)
events.outputs[2] = secondary
local near, behind, apart = newWindow(1), newWindow(2), newWindow(3)
apart.output = secondary
events.windows = { near, behind, apart }
for _, window in ipairs(events.windows) do
  emit('onWindowOpened', { window = window })
end
local monitor = newMonitor 'DP-1'
events.monitors[monitor.id] = monitor
emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
assert(desktop.panels:forSource(monitor)):setPose(lovr.math.newMat4(0, 1.5, -0.1))

-- Panels two and three metres away want less than scale 1, which every output
-- already has, so nothing is set.
place(near, 2)
place(behind, 3)
place(apart, 2)
frame()
assert(#events.modes == 0, 'an output already at its step is not set: ' .. #events.modes)

-- Half a metre away the ideal is 2. From scale 1 the chooser climbs while the
-- ideal clears the next rung by the raise margin, so it settles on 1.875; the
-- output shared by the two windows takes its nearest panel's scale, and the
-- monitor panel, nearer still, is not an output's.
place(near, 0.5)
frame()
assert(primary.scale == 1.875, 'the nearest panel raises its output: ' .. primary.scale)
assert(#modesOf(primary) == 1 and #modesOf(secondary) == 0, 'only the nearer output is set')

-- Inside the band around the rung nothing changes.
for _, distance in ipairs { 0.52, 0.5, 0.55, 0.49, 0.5 } do
  place(near, distance)
  frame()
end
assert(#modesOf(primary) == 1, 'a distance inside the band sets nothing: ' .. #modesOf(primary))

-- Stepping back far enough gives sharpness back, in one change.
place(near, 1)
frame()
assert(primary.scale == 1.125 and #modesOf(primary) == 2, 'a metre away the output steps down: ' .. primary.scale)

-- A hidden panel gives no distance, so the output follows the next nearest.
place(near, 0.5)
frame()
assert(primary.scale == 1.875, 'from 1.125 the climb settles on 1.875 again: ' .. primary.scale)
assert(desktop.panels:forSource(near)):setHidden(owner, { hidden = true })
frame()
assert(primary.scale == 1, 'with the near panel hidden the far one decides: ' .. primary.scale)
assert(desktop.panels:forSource(near)):setHidden(owner, { hidden = false })
frame()
assert(primary.scale == 1.875, 'shown again, the near panel decides again: ' .. primary.scale)

-- Unloading sets the output back to the scale it had before the first change.
desktop.consumers.scale:disable()
assert(primary.scale == 1, 'unloading restores the original scale: ' .. primary.scale)
local unloaded = #events.modes
frame()
assert(#events.modes == unloaded, 'an unloaded consumer sets nothing')

-- A new activation's first choice is made without hysteresis.
desktop.consumers.scale:enable()
frame()
assert(primary.scale == 2, 'the first choice takes the ideal rung outright: ' .. primary.scale)

-- A scale something else set since is left as it is.
primary:setMode { scale = 1.5 }
desktop.consumers.scale:disable()
assert(primary.scale == 1.5, 'unloading leaves a scale another plugin set')
assert(lovr.quit() == false)
desktop.runtime:close()

-- A desktop without the entry sets no scale.
events.modes = {}
primary.scale = 1
desktop = require 'fixture/graph' { patches = { { id = 'desktop/scale', disabled = true } } }
place(near, 0.2)
for _ = 1, 5 do
  frame()
end
assert(#events.modes == 0, 'without the entry no output is scaled')
assert(lovr.quit() == false)
desktop.runtime:close()
