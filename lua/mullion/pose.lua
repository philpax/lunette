-- The module encodes a pose as a string and decodes a string into a pose.
--
-- The per-window property store takes a number, a string, or a boolean and
-- refuses a table (docs/dev/lua-api.md#per-window-properties). The store keeps
-- arbitrary Lua values out, and a table as a property value would put them
-- in. A caller who needs structure encodes it into a string first.
--
-- This module is that encoding, in one place. The property store and a saved
-- arrangement on disk share the same sixteen-number form.
--
-- The format uses sixteen elements, not a position and an orientation,
-- because a pose may carry a scale and a decomposition would drop it. Nine
-- significant digits return a 32-bit float to its original value, so the
-- round-trip is exact.
--
-- This module holds no state and starts nothing, so a reload has nothing to
-- discard.

local pose = {}

-- How many numbers a pose is written as.
pose.ELEMENTS = 16

-- A `Mat4` as a string of sixteen numbers.
function pose.encode(matrix: Mat4): string
  local elements: { number } = { matrix:unpack(true) }
  local encoded: { string } = {}
  for index = 1, pose.ELEMENTS do
    encoded[index] = string.format('%.9g', elements[index])
  end
  return table.concat(encoded, ' ')
end

-- What `encode` wrote, as a fresh `Mat4`, or nothing.
--
-- Anything that is not sixteen finite numbers returns nothing, and no
-- partly-filled matrix is returned. A stored value persists after the Lua
-- state that wrote it is gone, and a configuration that sets the key directly
-- is as likely a source as this module is.
function pose.decode(text: boolean | number | string | nil): Mat4?
  if type(text) ~= 'string' then
    return nil
  end
  local encoded: string = text

  local elements: { number } = {}
  local count = 0
  for word in encoded:gmatch '%S+' do
    count = count + 1
    if count > pose.ELEMENTS then
      return nil
    end
    local number = tonumber(word)
    -- An infinity or a nan places a panel nowhere, and the value stays in the
    -- store across reloads. A nan is not equal to itself, so `number ~= number`
    -- catches it.
    if not number or number ~= number or number == math.huge or number == -math.huge then
      return nil
    end
    elements[count] = number
  end

  if count ~= pose.ELEMENTS then
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
