-- A protected call that reports its error rather than raising it.
--
-- A provider that calls several callbacks owned by other plugins, such as a
-- frame dispatcher or a listener registry, calls each one through this. An
-- error is reported through lunette.reportError, which is the path a raising
-- native callback takes, so every lunette.onError listener hears it, and the
-- caller goes on to the next callback: one plugin's defect does not hide
-- another's.

local lunette = require '@lunette'

local protected = {}

-- Calls run, answering whether it returned. When it raised, its error is
-- reported under context. A caller that needs what run computed assigns it to
-- a local of its own from inside run.
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
