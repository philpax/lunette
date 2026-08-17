-- A pose as a string, and back.
--
-- The per-window property store takes a number, a string, or a boolean and
-- refuses a table (docs/lua-api.md#per-window-properties). A table would hold
-- Lua values, which is the same problem the store exists to solve one level
-- down, so a caller wanting structure encodes it and knows that it did. This is
-- that encoding, in one place, because the store is not the only thing that
-- wants it: a saved arrangement on disk is the same sixteen numbers.
--
-- Sixteen elements rather than a position and an orientation, because a pose
-- may carry a scale and a decomposition would quietly drop it. Nine significant
-- digits, which is enough to bring a 32-bit float back unchanged, so the
-- round-trip is exact rather than nearly.
--
-- This module holds no state and starts nothing, so it registers no teardown
-- hook: there is nothing a reload could leave behind.

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
-- Anything that is not sixteen finite numbers answers nothing rather than a
-- partly-filled matrix. What is being read outlives the Lua state that wrote
-- it, and a configuration that wrote the key itself is as likely a source as
-- this module is.
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
    -- An infinity or a nan places a panel nowhere, and it would come back after
    -- every reload. nan is caught by comparing it with itself, which is the one
    -- comparison it fails.
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
