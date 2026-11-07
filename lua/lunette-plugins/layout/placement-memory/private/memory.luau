-- Captures and applies surface placements. The capture reads the surface it is given and the application writes to
-- it; neither keeps state.

local vocabulary = require '@lunette-contracts/vocabulary'
local config = require '../config'

local memory = {}

-- The placement of a surface that has a pose, with its width when it can be resized.
function memory.capture(surface: vocabulary.Surface): config.Placement?
  local pose = surface.pose
  if not pose then
    return nil
  end
  local x, y, z, angle, ax, ay, az = pose:getPose()
  return {
    position = vector.create(x, y, z),
    rotation = { angle, ax, ay, az },
    width = if surface.setSize then surface.width else nil,
  }
end

-- Moves a surface to a saved placement, and sizes it when the placement and the surface both allow it.
function memory.apply(surface: vocabulary.Surface, placement: config.Placement): ()
  local setPose = surface.setPose
  if setPose then
    local rotation = placement.rotation
    setPose(
      surface,
      lovr.math.mat4():translate(placement.position):rotate(rotation[1], rotation[2], rotation[3], rotation[4])
    )
  end
  local setSize, width = surface.setSize, placement.width
  if setSize and width then
    setSize(surface, width)
  end
end

return memory
