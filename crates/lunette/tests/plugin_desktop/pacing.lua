-- Frame pacing: a hidden panel's window falls to the background rate, video
-- and busy windows are exempt, a hidden monitor panel's capture pauses, a
-- window that loses its panel and every window at unload return to
-- unthrottled, and a desktop without the entry paces nothing.
local plugin = require '@lunette-plugin'
local panels = require '@lunette-contracts/panels'

local owner
local probe = plugin.define {
  name = 'pacing-probe',
  requires = { panels = panels.capability },
  init = function(context)
    owner = context
  end,
}
local desktop = require 'fixture/graph' { patches = { { insert = { id = 'probe', definition = probe } } } }

-- One frame, in which each window in `drawing` commits a new buffer first.
local function frame(drawing)
  for _, window in ipairs(drawing or {}) do
    window.commit += 1
  end
  lovr.update(0.016)
end
local function setHidden(source, hidden)
  assert(desktop.panels:forSource(source)):setHidden(owner, { hidden = hidden })
end

local quiet, playing, busy, shown = newWindow(1), newWindow(2), newWindow(3), newWindow(4)
playing.contentType = 'video'
local monitor = newMonitor 'DP-1'
events.monitors[monitor.id] = monitor
emit('onMonitorAdded', { id = monitor.id, monitor = monitor })
events.windows = { quiet, playing, busy, shown }
for _, window in ipairs(events.windows) do
  emit('onWindowOpened', { window = window })
end

-- Shown windows are left unthrottled, and the busy one redraws every frame.
for _ = 1, 10 do
  frame { busy }
end
assert(#events.rates == 0, 'a shown window is not throttled: ' .. #events.rates)
assert(#events.pauses == 0, 'a shown monitor panel keeps capturing')

-- Hiding drops the quiet window to the floor and the exempt ones to the exempt
-- rate: the video by its hint, though it commits nothing, and the busy window
-- by the commits it made while shown.
for _, window in ipairs { quiet, playing, busy } do
  setHidden(window, true)
end
setHidden(monitor, true)
frame()
assert(quiet.rate == 1, 'a hidden quiet window is paced at the floor: ' .. tostring(quiet.rate))
assert(playing.rate == 30, 'a hidden video is exempt: ' .. tostring(playing.rate))
assert(busy.rate == 30, 'a hidden busy window is exempt: ' .. tostring(busy.rate))
assert(shown.rate == nil, 'a shown window stays unthrottled')
assert(#events.pauses == 1 and events.pauses[1].paused == true, 'a hidden monitor panel pauses its capture')

-- A throttled window commits at its rate, which says nothing about what it
-- wants, so the busy window stays exempt while it stays hidden.
local applied = #events.rates
for _ = 1, 200 do
  frame()
end
assert(busy.rate == 30 and #events.rates == applied, 'a throttled window keeps its exemption')

-- Showing a panel returns its window to unthrottled and its capture to running.
setHidden(quiet, false)
setHidden(monitor, false)
frame()
assert(quiet.rate == nil and events.rates[#events.rates].window == quiet.id, 'a shown window is unthrottled again')
assert(#events.pauses == 2 and events.pauses[2].paused == false, 'a shown monitor panel resumes its capture')
setHidden(quiet, true)
setHidden(monitor, true)
frame()
assert(quiet.rate == 1 and monitor.paused == true)

-- Unloading returns every throttled window to unthrottled and resumes every
-- paused capture; loading again paces them again.
desktop.consumers.pacing:disable()
assert(quiet.rate == nil and playing.rate == nil and busy.rate == nil, 'unloading unthrottles every window')
assert(monitor.paused == false, 'unloading resumes the paused capture')
local unloaded = #events.rates
frame()
assert(#events.rates == unloaded, 'an unloaded consumer paces nothing')
desktop.consumers.pacing:enable()
frame()
assert(quiet.rate == 1 and playing.rate == 30, 'loading again paces the hidden windows')
assert(busy.rate == 1, 'a new activation starts without the history the last one kept')
assert(monitor.paused == true)

-- A pacing provider outage unloads the consumer with it.
desktop.providers.pacing:disable()
assert(quiet.rate == nil and playing.rate == nil, 'a provider outage unthrottles every window')
desktop.providers.pacing:enable()
frame()
assert(quiet.rate == 1, 'the consumer paces again when its provider returns')

-- A window whose panel is removed is no longer paced and is unthrottled.
desktop.consumers.adoption:disable()
frame()
assert(desktop.panels:forSource(quiet) == nil, 'the adopted panels are removed with adoption')
assert(quiet.rate == nil and playing.rate == nil, 'a window without a panel is unthrottled')
assert(monitor.paused == true, 'a monitor panel adoption did not place keeps its pause')
desktop.consumers.adoption:enable()
assert(lovr.quit() == false)
desktop.runtime:close()
assert(monitor.paused == false, 'closing the runtime resumes the capture')

-- A desktop without the entry leaves every rate alone.
events.rates, events.pauses = {}, {}
local without = require 'fixture/graph' {
  patches = {
    { id = 'desktop/pacing', disabled = true },
    { insert = { id = 'probe', definition = probe } },
  },
}
desktop = without
setHidden(quiet, true)
setHidden(monitor, true)
for _ = 1, 5 do
  frame()
end
assert(#events.rates == 0 and #events.pauses == 0, 'without the entry nothing is paced')
assert(lovr.quit() == false)
without.runtime:close()
