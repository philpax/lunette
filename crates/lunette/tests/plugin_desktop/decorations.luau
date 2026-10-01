-- Title bars that move their panels, hidden panels, the empty-scene hint, and
-- a surfaces outage that leaves panels rendering.
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local panels = require '@lunette-contracts/panels'
local vocabulary = require '@lunette-contracts/vocabulary'

local pointers, owner
local probe = plugin.define {
  name = 'decorations-probe',
  requires = { interaction = interaction.capability, panels = panels.capability },
  init = function(context)
    pointers, owner = context:require(interaction.capability), context
  end,
}
local desktop = require 'fixture/graph' { patches = { { insert = { id = 'probe', definition = probe } } } }
local consumers, providers = desktop.consumers, desktop.providers

local function texts()
  local found = {}
  for _, call in ipairs(events.draw) do
    if call[1] == 'text' then
      found[#found + 1] = call[2]
    end
  end
  return found
end
local function frame()
  events.draw, events.textures = {}, 0
  lovr.update(0.016)
  assert(lovr.draw(events.pass) == false)
end

-- The empty scene shows the hint, and a scene with a panel does not.
frame()
assert(table.find(texts(), 'lunette: no windows yet'), 'the empty scene shows the hint')

local window = newWindow(1)
events.windows = { window }
emit('onWindowOpened', { window = window })
local panel = assert(desktop.panels:forSource(window))
assert(panel.chrome == false, 'panels draw no chrome of their own')
frame()
assert(not table.find(texts(), 'lunette: no windows yet'), 'a panel hides the hint')
assert(table.find(texts(), 'Fixture window'), 'the decoration draws the title')

local function offered()
  local bar, itself
  for _, surface in ipairs(desktop.surfaces:all()) do
    if surface == panel then
      itself = surface
    elseif surface.kind == 'window' and surface.source == window then
      bar = surface
    end
  end
  return bar, itself
end
local bar, itself = offered()
assert(bar and itself, 'the panel and its title bar are both offered')
local px, py, pz = panel.pose:getPosition()
local bx, by, bz = bar.pose:getPosition()
assert(bx == px and bz == pz and by > py + panel.height / 2, 'the bar sits above the panel')

-- A grab of the bar carries the panel, and the drop is the panel's: its pose
-- is remembered on the window and the arrangement leaves it alone.
local pointer = pointers:newPointer(owner)
assert(pointer:beginGrab(bar, lovr.math.newMat4():translate(0, 1.5, 0)))
pointer:dragTo(lovr.math.newMat4():translate(1, 1.5, 0))
-- The fixture's matrices carry translations only, so the carried bar takes
-- the hand's position, and the panel hangs below it.
local movedX = panel.pose:getPosition()
assert(movedX == 1 and movedX ~= px, 'dragging the bar moves the panel')
assert(pointer:endGrab())
local stored = window.properties[vocabulary.POSE_PROPERTY]
assert(stored == vocabulary.encodePose(panel.pose), "the bar's drop stores the panel's pose")
pointer:destroy()
local other = newWindow(2)
events.windows = { window, other }
emit('onWindowOpened', { window = other })
frame()
assert(panel.pose:getPosition() == 1, 'a panel dropped by its bar stays out of the arrangement')

-- A hidden panel is neither drawn, offered, nor decorated.
local hiding = panel:setHidden(owner, { hidden = true })
frame()
assert(events.textures == 1, 'only the shown panel is drawn')
bar, itself = offered()
assert(bar == nil and itself == nil, 'a hidden panel and its bar are not offered')
hiding:dispose()
frame()
assert(events.textures == 2)
bar, itself = offered()
assert(bar and itself, 'a shown panel is offered again')

-- A surfaces outage stops pointing and decorations, and the panels keep
-- rendering; recovery offers them again.
providers.surfaces:disable()
assert(consumers.render:state() == 'active', 'a surfaces outage keeps rendering')
assert(consumers.decorations:state() ~= 'active' and consumers.pointing:state() ~= 'active')
frame()
assert(events.textures == 2, 'a surfaces outage keeps the panels drawing')
providers.surfaces:enable()
assert(consumers.decorations:state() == 'active')
bar, itself = offered()
assert(bar and itself, 'recovery offers the panels and bars again')

-- A removed panel's bar is forgotten.
other.dead = true
window.dead = true
frame()
assert(#desktop.surfaces:all() == 0 or select(1, offered()) == nil, 'removed panels leave no bars')
assert(bar.dead, 'the bar of a removed panel is dead')
assert(lovr.quit() == false)
