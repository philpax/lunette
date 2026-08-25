-- A pose encoded as a string, and decoded back.
--
-- The per-window property store takes a number, a string, or a boolean and
-- refuses a table (docs/lua-api.md#per-window-properties). A table would hold
-- Lua values, which is the problem the store exists to solve one level down.
-- A caller that wants structure therefore encodes it and records having done
-- so. This module holds that encoding in one place, because the property store
-- is not its only user: a saved arrangement on disk stores the same sixteen
-- numbers.
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

-- The string `encode` wrote, as a fresh `Mat4`, or nothing.
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
    -- An infinity or a nan would place a panel at an unusable pose and would
    -- come back after every reload. nan is caught by comparing the value with
    -- itself, which is the one comparison it fails.
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
