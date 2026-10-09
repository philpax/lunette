-- Development helpers for Lua tests. The `@testing` root is not installed.

local expect = require '@testing/expect'
local host = require '@testing/host'
local native = require '@testing/native'
local session = require '@testing/session'
local suite = require '@testing/suite'

-- Lists a rules service's sources in resolution order, from its inspection.
local function ruleSources(rules)
  local result = {}
  for _, entry in rules:inspect().registrations do
    if entry.kind == 'ruleSource' then
      result[#result + 1] = { name = entry.name, precedence = entry.details.precedence }
    end
  end
  return result
end

-- The diagnostic a runtime's snapshot holds for one of its instances.
local function diagnostic(runtime, instance)
  for _, entry in runtime:snapshot().instances do
    if entry.id == instance:id() then
      return entry.diagnostic
    end
  end
  return nil
end

return {
  suite = suite.new,
  expect = expect,
  native = native.new,
  start = session.start,
  boot = session.boot,
  -- The runner fails a case if it leaves a plugin failure report untaken.
  takeReports = host.takeReports,
  collect = host.collect,
  host = host,
  ruleSources = ruleSources,
  diagnostic = diagnostic,
}
