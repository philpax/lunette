-- Development helpers for Lua tests. The `@testing` root is not installed.

local expect = require '@testing/expect'
local host = require '@testing/host'
local native = require '@testing/native'
local session = require '@testing/session'
local suite = require '@testing/suite'

export type Native = native.Fake
export type Window = native.Window
export type Monitor = native.Monitor
export type Seat = native.Seat
export type Output = native.Output
export type Sink = native.Sink
export type InputCall = native.InputCall
export type DrawCall = native.DrawCall
export type Font = native.Font
export type NativeContext = native.PluginContext
export type NativeDefinition = native.PluginDefinition
export type NativeInstance = native.PluginInstance
export type NativeRuntime = native.PluginRuntime
export type PluginState = native.PluginState
export type PointerButton = native.PointerButton
export type ModifierName = native.ModifierName
export type Session = session.Session
export type ComposeEntry = session.ComposeEntry
export type Patch = session.Patch
export type Observed<T> = session.Observed<T>
export type Context = session.Context
export type Owner = session.Owner
export type Effect = session.Effect
export type Definition<C> = session.Definition<C>
export type InspectionDetails = session.InspectionDetails

export type function ConfiguredInput(factory: type): type
  local parameters = factory:parameters().head
  assert(parameters and parameters[1], 'configured definition factory has no input parameter')
  return parameters[1]
end

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
