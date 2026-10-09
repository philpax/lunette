-- Headset input uses each hand's pointing pose and controller. Per-laser readers can replace it.

local lunette = require '@lunette'
local contracts = require '@lunette-contracts/laser'

local input = {}

type Device = contracts.Device
type Hand = contracts.Hand
type Input = contracts.Input

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

-- Reads one frame of a hand, or nothing while the hand is not tracked.
function input.fromHeadset(hand: Hand, headset: HeadsetModule, mappings: { read [number]: Mapping }): Input?
  local device = devices[hand]
  if not headset.isTracked(device) then
    return nil
  end

  local controller = controllers[hand]
  local buttons: { [lunette.PointerButton]: boolean } = {}
  for index = 1, #mappings do
    local mapping = mappings[index]
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
    trigger = headset.getAxis(controller, 'trigger'),
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
