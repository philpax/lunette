-- An interaction `constrain` hook that keeps carried panels upright.
--
-- The default constraint answers the pose the hand would give a panel. This
-- keeps that pose's position and its turn about the vertical axis, and drops
-- any tilt or roll, so a panel carried by a tilted hand stays level.
local interaction = require '@lunette-plugins/interaction'
local surface = require '@lunette-contracts/surface'

return function(target: surface.Surface, pose: Mat4, base: interaction.ConstrainBase): Mat4
  local kept = base(target, pose)
  local x, y, z = kept:getPosition()
  -- Where the panel's front faces, flattened onto the floor.
  local forwardX, _, forwardZ = kept:mul(0, 0, -1, 0)
  local yaw = math.atan2(-forwardX, -forwardZ)
  return lovr.math.newMat4():translate(x, y, z):rotate(yaw, 0, 1, 0)
end
