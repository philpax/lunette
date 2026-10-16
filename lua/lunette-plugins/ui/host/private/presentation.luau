-- Places panels whose presentation the host controls: dialogs in front of their parent, or of the head, and follow
-- panels lazily ahead of the head.

local uiHost = require '@lunette-contracts/ui-host'
local records = require './records'

local presentation = {}

-- A follow panel sits this far ahead of the head and this far below eye level.
local FOLLOW_DISTANCE = 0.65
local FOLLOW_DROP = 0.18
-- It moves to a new target only when the head turns this far from the current one, so it does not swim.
local FOLLOW_THRESHOLD = math.rad(25)
local FOLLOW_RATE = 6
-- A dialog without a parent opens this far ahead of the head.
local DIALOG_DISTANCE = 0.6

export type Head = { position: vector, forward: vector }

-- The head's position and horizontal forward direction, or nil when the head is untracked.
function presentation.head(): Head?
  local headset = lovr.headset
  if not headset or not headset.getPosition then
    return nil
  end
  local x, y, z = headset.getPosition 'head'
  local fx, _, fz = headset.getDirection 'head'
  local length = math.sqrt(fx * fx + fz * fz)
  if length < 1e-6 then
    return nil
  end
  return { position = vector.pack(x, y, z), forward = vector.pack(fx / length, 0, fz / length) }
end

-- A pose at the point, facing the head.
local function facing(point: vector, head: vector): Mat4
  local toward = vector.pack(head.x - point.x, 0, head.z - point.z)
  local angle = math.atan2(toward.x, toward.z)
  return lovr.math.mat4():translate(point.x, point.y, point.z):rotate(angle, 0, 1, 0)
end

local function ahead(head: Head, distance: number, drop: number): vector
  local point = head.position + head.forward * distance
  return vector.pack(point.x, point.y - drop, point.z)
end

-- Advances one panel's presentation by a frame.
function presentation.place(record: records.Panel, head: Head?, dt: number, theme: uiHost.Theme): ()
  if record.presentation == 'attach' then
    local target = record.target
    if not target or target.dead or not target.pose then
      record.visible = false
      record.sync()
      return
    end
    record.minWidth = target.width or record.minWidth
    local above = (target.height or 0) / 2 + record.gap + record.height / 2
    record.pose:set(target.pose):translate(0, above, theme.elevation.contentOffset)
  elseif record.presentation == 'dialog' then
    local parent = record.parent
    if parent and not parent.dead then
      record.pose:set(parent.pose):translate(0, 0, theme.elevation.dialog)
      record.visible = parent.visible
    elseif record.followTarget == nil and head then
      -- A dialog without a parent opens ahead of the head and then stays where it opened.
      local target = facing(ahead(head, DIALOG_DISTANCE, 0.05), head.position)
      record.followTarget = lovr.math.newMat4(target)
      record.pose:set(target)
    end
  elseif record.presentation == 'follow' and head then
    local wanted = ahead(head, FOLLOW_DISTANCE, FOLLOW_DROP)
    local target = record.followTarget
    if target == nil then
      record.followTarget = lovr.math.newMat4(facing(wanted, head.position))
      record.pose:set(record.followTarget :: Mat4)
      return
    end
    local tx, ty, tz = target:getPosition()
    local current = vector.pack(tx, ty, tz) - head.position
    local desired = wanted - head.position
    local cosine = vector.dot(vector.normalize(vector.pack(current.x, 0, current.z)), head.forward)
    if
      math.acos(math.clamp(cosine, -1, 1)) > FOLLOW_THRESHOLD
      or math.abs(vector.magnitude(current) - vector.magnitude(desired)) > 0.3
    then
      target:set(facing(wanted, head.position))
    end
    local blend = 1 - math.exp(-dt * FOLLOW_RATE)
    local px, py, pz = record.pose:getPosition()
    local x, y, z = px + (tx - px) * blend, py + (ty - py) * blend, pz + (tz - pz) * blend
    record.pose:set(facing(vector.pack(x, y, z), head.position))
  end
end

-- Whether presses on a panel are blocked by an open modal dialog.
function presentation.blocked(panel: records.Panel, panels: { records.Panel }): boolean
  local owner: records.Panel = panel
  while owner.overlay do
    owner = owner.overlay.opener
  end
  for _, other in panels do
    if other.presentation == 'dialog' and not other.dead and other ~= owner then
      if other.modality == 'session' or other.parent == owner then
        return true
      end
    end
  end
  return false
end

return presentation
