local suite = require '@spec/suite'
local mounted = {
  { name = '@spec/mullion/persist/file_spec', cases = 15 },
  { name = '@spec/mullion/persist/arrangement_spec', cases = 18 },
  { name = '@spec/mullion/persist/format_spec', cases = 15 },
}
local count = 0
for _, expected in ipairs(mounted) do
  local collected = require(expected.name)
  assert(suite.isSuite(collected), expected.name .. ' must return a suite')
  assert(#collected.cases == expected.cases, expected.name .. ' must run every expected case')
  for _, case in ipairs(collected.cases) do
    local ok, failure = pcall(case.run)
    assert(ok, collected.name .. ': ' .. case.name .. ': ' .. tostring(failure))
    count += 1
  end
end
persistenceSpecCases = count
