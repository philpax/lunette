-- Interaction and laser outages, and an interaction outage in the middle of a
-- drag, in the shipped desktop composition.
local persist = require '@lunette-desktop/persist'
local vocabulary = require '@lunette-contracts/vocabulary'
local desktop = require 'fixture/graph'()
local providers, consumers, service = desktop.providers, desktop.consumers, desktop.panels

local function liveSeats()
  local count = 0
  for _, seat in ipairs(events.seats) do
    if not seat.dead then
      count += 1
    end
  end
  return count
end
local function frame()
  events.textures = 0
  lovr.update(0.016)
  assert(lovr.draw(events.pass) == false)
end

local window = newWindow(1)
events.windows = { window }
emit('onWindowOpened', { window = window })
local panel = assert(service:forSource(window))
frame()
assert(events.textures == 1 and liveSeats() == 2)

-- Pointing is a consumer of its own, so an outage of either provider it rests
-- on leaves panels placed, updating, and drawing.
for _, name in ipairs { 'interaction', 'laser' } do
  providers[name]:disable()
  assert(consumers.pointing:state() ~= 'active', name .. ' outage unloads pointing')
  assert(
    consumers.base:state() == 'active' and consumers.arrange:state() == 'active',
    name .. ' outage keeps rendering and arranging'
  )
  assert(service:forSource(window) == panel and not panel.dead, name .. ' outage keeps the panel')
  assert(liveSeats() == 0, name .. ' outage releases the laser seats')
  frame()
  assert(events.textures == 1, name .. ' outage keeps panels drawing')
  providers[name]:enable()
  assert(consumers.pointing:state() == 'active' and liveSeats() == 2, name .. ' recovery restores pointing')
end

-- The right beam grabs the panel in front and drags it.
frame()
events.grip = true
frame()
events.handX = 0.5
frame()
local x = panel.pose:getPosition()
assert(x == 0.5, 'the drag moved the panel')

-- Interaction goes away mid-drag. The drop that ends the grab is saved and
-- stored, so the saved arrangement agrees with the native pose property.
local writes = events.writes
providers.interaction:disable()
events.grip = false
events.handX = nil
local stored = window.properties[vocabulary.POSE_PROPERTY]
assert(stored ~= nil, 'the abandoned grab stored the pose')
assert(events.writes == writes + 1, 'the abandoned grab saved the arrangement')
local loaded = persist.read(events.saved)
assert(loaded.kind == 'arrangement')
local entry = persist.entries(loaded.file)[1]
assert(entry and entry.pose == stored, 'the saved pose and the native property agree')
providers.interaction:enable()
frame()
assert(events.textures == 1)
assert(lovr.quit() == false)
