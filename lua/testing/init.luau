-- Development helpers for Lua tests. The `@testing` root is not installed.

local expect = require '@testing/expect'
local host = require '@testing/host'
local native = require '@testing/native'
local session = require '@testing/session'
local suite = require '@testing/suite'

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
}
