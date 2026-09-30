-- Beam and cursor rendering for one laser.

local contracts = require '@lunette-contracts/laser'

local draw = {}

type Laser = contracts.Laser

type Color = contracts.Color

function draw.laser(target: Laser, pass: Pass): ()
  local frame = target.input
  if target.dead or not frame then
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

  pass:setColor(color[1], color[2], color[3], color[4])
  pass:setDepthTest()
  pass:setDepthWrite(false)
  pass:line(originX, originY, originZ, endX, endY, endZ)
  if hovered then
    pass:sphere(endX, endY, endZ, style.cursorRadius)
  end
  pass:setDepthTest 'lequal'
  pass:setDepthWrite(true)
  pass:setColor(1, 1, 1, 1)
end

return draw
