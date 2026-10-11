-- Development helpers for Lua tests. The `@testing` root is not installed.

local expect = require '@testing/expect'
local host = require '@testing/host'
local native = require '@testing/native'
local session = require '@testing/session'
local suite = require '@testing/suite'

-- The diagnostic a runtime's snapshot holds for one of its instances.
-- Native and adapter handles retain their own receivers behind this read-only view.
export type SnapshotRuntime<R> = {
  read snapshot: (R) -> { read instances: { read [number]: { read id: string, read diagnostic: string? } } },
}
export type IdentifiedInstance<I> = { read id: (I) -> string }

local function diagnostic<R, I>(runtime: R & SnapshotRuntime<R>, instance: I & IdentifiedInstance<I>): string?
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
  diagnostic = diagnostic,
}
