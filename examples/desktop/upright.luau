-- The constraint preserves position and yaw while removing tilt and roll.
local interaction = require '@lunette-plugins/interaction'
local surface = require '@lunette-contracts/surface'

return function(target: surface.Surface, pose: Mat4, base: interaction.ConstrainBase): Mat4
  local kept = base(target, pose)
  local x, y, z = kept:getPosition()
  local forwardX, _, forwardZ = kept:mul(0, 0, -1, 0)
  local yaw = math.atan2(-forwardX, -forwardZ)
  return lovr.math.newMat4():translate(x, y, z):rotate(yaw, 0, 1, 0)
end
