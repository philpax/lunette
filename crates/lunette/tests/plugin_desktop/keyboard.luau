-- The wrist keyboard draws only its own keyboard, takes its options, and
-- pulses the laser that pressed it through the pointer's haptics.
local plugin = require '@lunette-plugin'
local keyboardModule = require '@lunette-plugins/keyboard'
local keyboardContract = require '@lunette-contracts/keyboard'
local interactionContract = require '@lunette-contracts/interaction'

local drawnBy = {}
local tracing = keyboardModule.define {
  drawKey = function(pass, key, state, base)
    drawnBy[state.keyboard] = (drawnBy[state.keyboard] or 0) + 1
    base(pass, key, state)
  end,
}
local desktop = require 'fixture/graph' {
  patches = {
    { id = 'keyboard', definition = tracing },
    { id = 'desktop/keyboard', config = { hand = 'right', size = 0.2, haptic = { strength = 0.4 } } },
  },
}
for id, instance in pairs(desktop.instances) do
  assert(instance:state() == 'active', id .. ': ' .. tostring(instance:diagnostic()))
end

-- Another plugin's keyboard, visible and never offered or drawn by its owner.
local mine, pointers
desktop.runtime
  :use(
    plugin.define {
      name = 'other-keyboard',
      requires = { keyboard = keyboardContract.capability, interaction = interactionContract.capability },
      init = function(ctx)
        mine = ctx:require(keyboardContract.capability):new(ctx)
        pointers = ctx:require(interactionContract.capability)
      end,
    },
    {}
  )
  :enable()
assert(mine and mine.visible)

local wrist
for _, candidate in ipairs(desktop.surfaces:all()) do
  if candidate.grabbable == false and candidate.width == 0.2 then
    wrist = candidate
  end
end
assert(wrist, 'the wrist button takes the configured size')

local right
for _, pointer in ipairs(pointers:pointers()) do
  if pointer.seat and pointer.seat.name == 'laser.right' then
    right = pointer
  end
end
assert(right, 'the right laser has a pointer')

-- Pressing the button with the right laser shows the wrist keyboard and pulses
-- that laser's controller with the configured haptic.
local before = events.haptics or 0
wrist:onPress(nil, nil, right)
assert(events.haptics == before + 1)
assert(events.haptic.device == 'hand/right' and events.haptic.strength == 0.4 and events.haptic.duration == 0.05)

local shown
for _, candidate in ipairs(desktop.surfaces:all()) do
  if candidate ~= mine and candidate.setLayer then
    shown = candidate
  end
end
assert(shown and shown.visible, 'the wrist keyboard is offered once shown')

events.draw = {}
lovr.update(0.016)
assert(lovr.draw(events.pass) == false)
assert((drawnBy[shown] or 0) > 0, 'the wrist keyboard is drawn')
assert(drawnBy[mine] == nil, "another owner's keyboard is not drawn by the wrist consumer")

assert(lovr.quit() == false)

-- An option the consumer does not take, or a hand it does not know, fails its
-- activation by name.
for _, case in ipairs {
  { config = { hand = 'middle' }, message = 'plugin desktop/keyboard: option hand is left or right, not middle' },
  { config = { offset = { 1, 2 } }, message = 'plugin desktop/keyboard: option offset is three numbers, not 2' },
  { config = { colour = 1 }, message = 'plugin desktop/keyboard: unknown option colour' },
} do
  local diagnostic
  local running = require('@lunette-plugin').start(require('@lunette-desktop').compose {
    entries = {
      { id = 'frame', definition = require('@lunette-plugins/frame').definition },
      { id = 'surfaces', definition = require('@lunette-plugins/surfaces').definition },
      { id = 'focus', definition = require('@lunette-plugins/focus').definition },
      { id = 'keyboard', definition = keyboardModule.definition },
      { id = 'desktop/keyboard', definition = require '@lunette-desktop/keyboard', config = case.config },
    },
  })
  diagnostic = tostring(running.instances['desktop/keyboard']:diagnostic())
  assert(diagnostic:find(case.message, 1, true), diagnostic)
  running.runtime:close()
end
