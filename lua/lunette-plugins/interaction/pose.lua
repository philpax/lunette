-- Encode and decode poses for the native per-window property store.
--
-- The store accepts scalar values, not matrices. This provider keeps the same
-- sixteen-number representation used by the standard library without depending
-- on the legacy pose module.

local pose = {}

local ELEMENTS = 16

function pose.encode(matrix: Mat4): string
  local elements: { number } = { matrix:unpack(true) }
  local encoded: { string } = {}
  for index = 1, ELEMENTS do
    encoded[index] = string.format('%.9g', elements[index])
  end
  return table.concat(encoded, ' ')
end

function pose.decode(value: boolean | number | string | nil): Mat4?
  if type(value) ~= 'string' then
    return nil
  end

  local elements: { number } = {}
  local count = 0
  for word in value:gmatch '%S+' do
    count += 1
    if count > ELEMENTS then
      return nil
    end
    local number = tonumber(word)
    if not number or number ~= number or number == math.huge or number == -math.huge then
      return nil
    end
    elements[count] = number
  end

  if count ~= ELEMENTS then
    return nil
  end

  return lovr.math.newMat4():set(
    elements[1],
    elements[2],
    elements[3],
    elements[4],
    elements[5],
    elements[6],
    elements[7],
    elements[8],
    elements[9],
    elements[10],
    elements[11],
    elements[12],
    elements[13],
    elements[14],
    elements[15],
    elements[16]
  )
end

return pose
