-- Places the keyboard horizontally in front of the head only when it becomes visible.
local keyboard = require '@lunette-contracts/keyboard'
local config = require '@lunette-plugins/desktop/keyboard/config'

return function(target: keyboard.Keyboard, placement: config.Placement): ()
  local head = vector.pack(lovr.headset.getPosition 'head')
  local forwardX, _, forwardZ = lovr.headset.getDirection 'head'
  local flat = vector.pack(forwardX, 0, forwardZ)
  if flat:length() < 0.001 then
    flat = vector.pack(0, 0, -1)
  end
  flat = flat:normalize()
  local position = head + flat * placement.distance - vector.pack(0, placement.drop, 0)
  target:setPose(
    lovr.math
      .newMat4()
      :translate(position)
      :rotate(math.atan2(-flat.x, -flat.z), 0, 1, 0)
      :rotate(-placement.tilt, 1, 0, 0)
  )
end
