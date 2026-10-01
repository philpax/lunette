-- Pure input shaping shared by the headset reader and test readers.

local vocabulary = require '@lunette-contracts/vocabulary'

local input = {}

export type Device = 'hand/left/point' | 'hand/right/point' | 'hand/left' | 'hand/right'
export type Hand = 'left' | 'right'
export type Input = vocabulary.Input
export type Reader = (Hand) -> Input?

local devices: { [string]: Device } = {
  left = 'hand/left/point',
  right = 'hand/right/point',
}

local controllers: { [string]: Device } = {
  left = 'hand/left',
  right = 'hand/right',
}

function input.fromHeadset(hand: Hand, headset: HeadsetModule): Input?
  local device = devices[hand]
  if not headset.isTracked(device) then
    return nil
  end

  local controller = controllers[hand]
  local scrollX, scrollY = headset.getAxis(controller, 'thumbstick')
  local poseX, poseY, poseZ, angle, axisX, axisY, axisZ = headset.getPose(device)
  return {
    pose = lovr.math.newMat4(poseX, poseY, poseZ, angle, axisX, axisY, axisZ),
    origin = vector.pack(headset.getPosition(device)),
    direction = vector.pack(headset.getDirection(device)),
    trigger = headset.isDown(controller, 'trigger') or false,
    grip = headset.isDown(controller, 'grip') or false,
    scrollX = scrollX or 0,
    scrollY = scrollY or 0,
    dt = headset.getDeltaTime(),
  }
end

input.devices = devices
input.controllers = controllers

return input
