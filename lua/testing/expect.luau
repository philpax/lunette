-- Assertions for the Lua tests.
--
-- Each raises on failure with a message saying what is wanted and what
-- arrived, and the runner turns that into the case's report. A case stops
-- at its first failure. The message reports the first thing that went wrong,
-- not the state of the run after it.

local expect = {}

-- Renders a value for a failure message. Tables render by address, because
-- a test comparing two tables is comparing identity.
local function show(value: unknown): string
  if type(value) == 'string' then
    return string.format('%q', value)
  end
  return tostring(value)
end

local function fail(message: string): ()
  error(message, 3)
end

function expect.equal(actual: unknown, wanted: unknown, context: string?)
  if actual ~= wanted then
    fail((context or 'value') .. ': wanted ' .. show(wanted) .. ', got ' .. show(actual))
  end
end

function expect.truthy(actual: unknown, context: string?)
  if not actual then
    fail((context or 'value') .. ': wanted something truthy, got ' .. show(actual))
  end
end

function expect.falsy(actual: unknown, context: string?)
  if actual then
    fail((context or 'value') .. ': wanted something falsy, got ' .. show(actual))
  end
end

-- Equal to within `tolerance`. Every number a test compares comes out of
-- floating-point arithmetic, so an exact comparison asserts the order the
-- operations appear in the code.
function expect.near(actual: unknown, wanted: number, tolerance: number, context: string?)
  -- The local fixes the type of `actual`: the arithmetic below reads the
  -- local, not the `unknown` parameter.
  local near = actual
  if type(near) ~= 'number' then
    fail((context or 'value') .. ': wanted a number near ' .. show(wanted) .. ', got ' .. show(actual))
    return
  end
  -- Catches nan as well as a value that is far away: every comparison
  -- against nan is false, so the subtraction below would pass it.
  if not (math.abs(near - wanted) <= tolerance) then
    fail(
      (context or 'value')
        .. ': wanted '
        .. show(wanted)
        .. ' to within '
        .. show(tolerance)
        .. ', got '
        .. show(actual)
    )
  end
end

-- Asserts that `run` raises, and returns the message it raises with. `pattern`
-- is optional and is a Lua pattern the message has to contain. A case can
-- assert that the error message matches the pattern, not that it is any
-- error.
function expect.raises(run: () -> (), pattern: string?, context: string?): string
  local ok, message = pcall(run)
  if ok then
    fail((context or 'call') .. ': wanted it to raise, and it returned')
  end
  message = tostring(message)
  if pattern and not message:find(pattern) then
    fail((context or 'call') .. ": raised with a message not matching '" .. pattern .. "': " .. message)
  end
  return message
end

return expect
