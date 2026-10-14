local contracts = require '@lunette-contracts/laser'
local config = require '@lunette-plugins/laser/config'
local passState = require '@lunette-plugins/graphics/pass-state'
local dragIcon = require '@lunette-plugins/laser/drag-icon'

local draw = {}

type Laser = config.Beam

type Color = contracts.Color

function draw.laser(target: Laser, pass: Pass): ()
  local frame = target.input
  if not frame then
    return
  end

  local originX, originY, originZ = frame.origin:unpack()
  local directionX, directionY, directionZ = frame.direction:unpack()
  local length = math.sqrt(directionX * directionX + directionY * directionY + directionZ * directionZ)
  if not (length > 0) then
    return
  end

  local style = target.style
  local hovered = target.pointer.hovered
  local distance = style.length
  if hovered and target.pointer.distance then
    distance = target.pointer.distance
  end

  local endX = originX + directionX / length * distance
  local endY = originY + directionY / length * distance
  local endZ = originZ + directionZ / length * distance
  local color: Color = if hovered then style.hoverColor else style.color

  passState.withRestore(pass, function()
    pass:setShader()
    pass:setMaterial(nil)
    pass:setColor(color[1], color[2], color[3], color[4])
    pass:setDepthTest()
    pass:setDepthWrite(false)
    pass:line(originX, originY, originZ, endX, endY, endZ)
    if hovered then
      pass:sphere(endX, endY, endZ, style.cursorRadius)
    end
  end)

  -- A drag's icon follows the pointer, so it is drawn where the beam ends.
  local drag = if target.seat.dead then nil else target.seat.drag
  if drag then
    dragIcon.draw(target.icon, pass, drag, vector.pack(endX, endY, endZ), frame.origin, target.iconShaders)
  end
end

return draw
