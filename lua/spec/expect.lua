-- Assertions for the spec suite.
--
-- Each raises on failure with a message saying what was wanted and what
-- arrived, and `spec.runner` turns that into the case's report. They raise
-- rather than returning a verdict so that a case stops at its first failure,
-- which is what makes the message about the first thing that went wrong rather
-- than about the wreckage after it.

local expect = {}

-- Renders a value for a failure message. Tables are rendered by address,
-- because a spec comparing two tables is comparing identity.
local function show(value)
  if type(value) == 'string' then
    return string.format('%q', value)
  end
  return tostring(value)
end

local function fail(message)
  error(message, 3)
end

function expect.equal(actual, wanted, context)
  if actual ~= wanted then
    fail((context or 'value') .. ': wanted ' .. show(wanted) .. ', got ' .. show(actual))
  end
end

function expect.truthy(actual, context)
  if not actual then
    fail((context or 'value') .. ': wanted something truthy, got ' .. show(actual))
  end
end

function expect.falsy(actual, context)
  if actual then
    fail((context or 'value') .. ': wanted something falsy, got ' .. show(actual))
  end
end

-- Equal to within `tolerance`. Every number this suite compares came out of
-- floating-point arithmetic, so an exact comparison would be asserting the
-- order the operations happened to be written in.
function expect.near(actual, wanted, tolerance, context)
  if type(actual) ~= 'number' then
    fail((context or 'value') .. ': wanted a number near ' .. show(wanted) .. ', got ' .. show(actual))
  end
  -- Catches nan as well as a value that is merely far away: every comparison
  -- against nan is false, so the subtraction below would pass it.
  if not (math.abs(actual - wanted) <= tolerance) then
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

-- Asserts that `run` raises, and returns the message it raised with. `pattern`
-- is optional and is a Lua pattern the message has to contain, so a case can
-- assert it got the error it meant rather than any error at all.
function expect.raises(run, pattern, context)
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
