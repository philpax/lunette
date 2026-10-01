-- The desktop example in examples/desktop: its main.lua keeps carried panels
-- upright, maps a second controller button, moves the reload key, recolours
-- the title bars, and inserts a binding that hides every window.
require 'main'
lovr.load()
local window = newWindow(1)
events.windows = { window }
emit('onWindowOpened', { window = window })
local function frame()
  events.draw, events.textures = {}, 0
  lovr.update(0.016)
  assert(lovr.draw(events.pass) == false)
end
frame()
assert(events.textures == 1)
local coloured = false
for _, call in ipairs(events.draw) do
  if call[1] == 'setColor' and call[2] == 0.3 and call[3] == 0.12 and call[4] == 0.2 then
    coloured = true
  end
end
assert(coloured, 'the title bar takes the configured colour')

-- Control, alt, and H hide every window, and show them again.
events.held.lctrl, events.held.lalt = true, true
lovr.keypressed('h', 0, false)
frame()
assert(events.textures == 0, 'the binding hid the window')
lovr.keypressed('h', 0, false)
frame()
assert(events.textures == 1, 'the binding showed the window again')
events.held = {}

-- F5 alone is no longer the reload key; control and F5 are.
local enumerations = events.enumerations
lovr.keypressed('f5', 0, false)
assert(events.enumerations == enumerations, 'F5 alone does not reload')
events.held.lctrl = true
events.logs = {}
lovr.keypressed('f5', 0, false)
assert(#events.logs == 0, 'the reload failed: ' .. tostring(events.logs[1] and events.logs[1][1]))
assert(events.enumerations == enumerations + 1, 'control and F5 reload')
events.held = {}

-- A grab still carries the panel through the upright constraint.
frame()
events.grip = true
frame()
events.handX = 0.5
frame()
events.grip = false
events.handX = nil
frame()
local stored = window.properties['lunette.pose']
assert(stored and stored:match '^%S+', 'the drop stored the carried pose')
-- The thirteenth of the sixteen numbers is the x of the translation.
local x = tonumber(stored:match '(%S+) %S+ %S+ %S+$')
assert(x == 0.5, 'the panel moved with the hand: ' .. tostring(stored))
assert(lovr.quit() == false)
