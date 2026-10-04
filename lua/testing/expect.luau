local expect = {}

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

-- Floating-point results need a tolerance because exact equality depends on operation order.
function expect.near(actual: unknown, wanted: number, tolerance: number, context: string?)
  local near = actual
  if type(near) ~= 'number' then
    fail((context or 'value') .. ': wanted a number near ' .. show(wanted) .. ', got ' .. show(actual))
    return
  end
  -- Every ordered comparison with NaN is false, so the tolerance check must reject it explicitly.
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

-- The optional pattern uses Lua pattern syntax.
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
