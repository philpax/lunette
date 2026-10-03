-- The scaffolding of the Lua tests, in one place. A test file is a `.luau` file directly inside a `tests`
-- directory beside the module it covers; its helpers go in `tests/support/`. The runner,
-- `crates/lunette/tests/lua/`, runs each test file in a fresh state. A test file looks like this:
--
--   local testing = require '@testing'
--   local expect = testing.expect
--   local test = testing.suite()
--
--   test('a case named as a sentence', function()
--     expect.equal(1 + 1, 2, 'the sum')
--   end)
--
--   return test
--
-- The root is development-only: it is not installed, and no installed module requires it.

local expect = require '@testing/expect'
local host = require '@testing/host'
local native = require '@testing/native'
local session = require '@testing/session'
local suite = require '@testing/suite'

return {
  -- A new suite, which the file adds its cases to and returns.
  suite = suite.new,
  -- The assertions.
  expect = expect,
  -- Installs a fresh fake native API and answers it.
  native = native.new,
  -- Starts a few plugins in a runtime of their own.
  start = session.start,
  -- Starts a composition driven through LÖVR's callbacks, with a fake native API.
  boot = session.boot,
  -- Takes every plugin failure reported since the last take. The runner fails a case during which a plugin
  -- failure is reported that the case does not take.
  takeReports = host.takeReports,
  -- A full garbage collection, for a case asserting what a weak table no longer holds.
  collect = host.collect,
  -- The host's other powers: `shutdown`, `reload`, `setReadonly`, and `useConfiguration`.
  host = host,
}
