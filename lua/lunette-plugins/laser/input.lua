-- Pure input shaping shared by the headset reader and test readers.
--
-- `devices` names each hand's pointing pose and `controllers` the controller
-- that holds its buttons, thumbstick, and haptics. `CONTROLS` are the
-- controller buttons a pointer button can be mapped from.

local lunette = require '@lunette'
local vocabulary = require '@lunette-contracts/vocabulary'

local input = {}

export type Device = 'hand/left/point' | 'hand/right/point' | 'hand/left' | 'hand/right'
export type Hand = 'left' | 'right'
export type Input = vocabulary.Input
export type Reader = (Hand) -> Input?

-- One controller button that presses one pointer button.
export type Mapping = {
  read control: DeviceButton,
  read button: lunette.PointerButton,
}

local devices: { [string]: Device } = {
  left = 'hand/left/point',
  right = 'hand/right/point',
}

local controllers: { [string]: Device } = {
  left = 'hand/left',
  right = 'hand/right',
}

-- LÖVR's controller buttons, the closed set `lovr.headset.isDown` reads.
input.CONTROLS = table.freeze {
  'trigger',
  'thumbstick',
  'thumbrest',
  'thumbtap',
  'touchpad',
  'grip',
  'menu',
  'a',
  'b',
  'x',
  'y',
  'dpup',
  'dpdown',
  'dpleft',
  'dpright',
  'bumper',
  'nib',
} :: { DeviceButton }

-- Reads one frame of a hand from the headset, or nothing while the hand is
-- not tracked. Each mapping whose control is down holds its pointer button.
function input.fromHeadset(hand: Hand, headset: HeadsetModule, mappings: { Mapping }): Input?
  local device = devices[hand]
  if not headset.isTracked(device) then
    return nil
  end

  local controller = controllers[hand]
  local buttons: { [lunette.PointerButton]: boolean } = {}
  for _, mapping in ipairs(mappings) do
    if headset.isDown(controller, mapping.control) then
      buttons[mapping.button] = true
    end
  end
  local scrollX, scrollY = headset.getAxis(controller, 'thumbstick')
  local poseX, poseY, poseZ, angle, axisX, axisY, axisZ = headset.getPose(device)
  return {
    pose = lovr.math.newMat4(poseX, poseY, poseZ, angle, axisX, axisY, axisZ),
    origin = vector.pack(headset.getPosition(device)),
    direction = vector.pack(headset.getDirection(device)),
    buttons = buttons,
    grip = headset.isDown(controller, 'grip') or false,
    scrollX = scrollX or 0,
    scrollY = scrollY or 0,
    dt = headset.getDeltaTime(),
  }
end

input.devices = devices
input.controllers = controllers

return input
