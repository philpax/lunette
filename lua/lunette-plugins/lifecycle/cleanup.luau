-- Teardown runs every step, so one failure cannot leak the resources released after it.
local cleanup = {}

function cleanup.run(label: string, operations: { () -> () }): ()
  local failures: { string } = {}
  for _, operation in operations do
    local ok, failure = pcall(operation)
    if not ok then
      failures[#failures + 1] = tostring(failure)
    end
  end
  if #failures > 0 then
    error(label .. ': ' .. table.concat(failures, '; '), 0)
  end
end

return cleanup
