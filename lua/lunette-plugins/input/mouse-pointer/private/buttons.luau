-- Mouse button state between frames. A press that is released before the next frame is still reported down for that
-- frame, so a quick click reaches the pointer as a press and a release.

local lunette = require '@lunette'

local buttons = {}

export type State = {
  -- Buttons physically down.
  held: { [lunette.PointerButton]: boolean },
  -- Buttons pressed since the last sample.
  pressed: { [lunette.PointerButton]: boolean },
}

-- LÖVR numbers mouse buttons from 1: primary, secondary, then middle.
local BY_NUMBER: { [number]: lunette.PointerButton } = { 'left', 'right', 'middle' }

function buttons.new(): State
  return { held = {}, pressed = {} }
end

-- The pointer button for a LÖVR mouse button number, or nil for a button the pointer does not map.
function buttons.fromNumber(number: number): lunette.PointerButton?
  return BY_NUMBER[number]
end

function buttons.press(state: State, button: lunette.PointerButton): ()
  state.held[button] = true
  state.pressed[button] = true
end

function buttons.release(state: State, button: lunette.PointerButton): ()
  state.held[button] = nil
end

-- The buttons to report this frame. Sampling ends the frame's latched presses.
function buttons.sample(state: State): { [lunette.PointerButton]: boolean }
  local result: { [lunette.PointerButton]: boolean } = {}
  for button in state.held do
    result[button] = true
  end
  for button in state.pressed do
    result[button] = true
  end
  table.clear(state.pressed)
  return result
end

return buttons
