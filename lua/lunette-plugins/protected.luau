-- A protected call that reports its error through lunette.reportError rather than raising it, so a
-- provider calling other plugins' callbacks goes on to the next and one defect does not hide another.

local lunette = require '@lunette'

local protected = {}

-- Calls run, answering whether it returned; when it raised, its error is reported under context.
function protected.call(context: string, run: () -> ()): boolean
  local message: string? = nil
  local traceback = ''
  local ok = xpcall(run, function(raised: unknown)
    message = tostring(raised)
    traceback = debug.traceback('', 2)
  end)
  if ok then
    return true
  end
  lunette.reportError {
    context = context,
    message = message or 'the callback raised nothing describable',
    traceback = traceback,
  }
  return false
end

return protected
