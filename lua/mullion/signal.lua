-- Signals: named notification points on an object, and property-change
-- notification built on them.
--
-- The native layer pushes flat events through LÖVR's queue, and
-- docs/lua-api.md#events states that turning those into per-object
-- notification is Lua's job. This is that layer, and it is the whole of it: a
-- handler is a function, a signal is a string, and an object is anything that
-- can key a table.
--
-- A native handle is not a usable key: every read produces a fresh Lua value.
-- Use the stable `win.id` as the key, or emit on a caller-owned object such as a
-- panel. See docs/lua-api.md#handles.
--
-- The registry holds objects weakly, so a connection is not the reason an
-- object is still reachable. That is not the whole story, because Lua 5.1 has
-- no ephemeron tables: a handler connected with `connect` is held strongly, so
-- a handler closing over the object it is connected to keeps that object alive
-- through the registry's own value. `weakConnect` is what a caller reaches for
-- when that matters, and a panel connecting to something that outlives it is
-- exactly the case.

local teardown = require '@mullion/teardown'

local signal = {}

-- A handler, parameterised by what it is connected to: `connect` infers it from
-- the object, so a handler's first parameter is the object's own type and not a
-- value the checker has stopped looking at.
type Handler<T> = (object: T, ...any) -> ()

-- A connection: the handler to call, nil once the handler it held weakly has
-- been collected.
type Record = {
  -- The registry spans every object, so what it holds is the erased form.
  handler: Handler<any>?,
}
-- The registry, as `{ [object] = { [name] = { Record, ... } } }`.
type Records = { Record }
type ByName = { [string]: Records }

-- Declared here and defined below the public API, so that the file reads
-- surface-first. `function name()` assigns to the local when one is in scope,
-- so none of these becomes a global.
local newRecord, recordsFor, prune

-- Every connection, as `{ [object] = { [name] = { record, ... } } }`.
--
-- Weak keys, per the note above. Rebuilt rather than appended to when the
-- module is loaded, which is what makes a soft reload — which discards the Lua
-- state and re-runs this file — leave no connections behind.
local connections: { [unknown]: ByName } = setmetatable({}, { __mode = 'k' })

-- The name a property's change is announced under.
--
-- awesome spells it `property::<key>` and configurations written against it
-- read the same way here, which is worth more than a spelling of lunette's own.
function signal.propertyName(key: string): string
  if type(key) ~= 'string' then
    error('mullion.signal: a property is named by a string, not a ' .. type(key), 2)
  end
  return 'property::' .. key
end

-- Connects `handler` to `name` on `object`.
--
-- The handler is called as `handler(object, ...)` with whatever `emit` was
-- given, in the order the connections were made. The registry holds it
-- strongly; see `weakConnect` for when that is the wrong thing.
--
-- Connecting the same handler twice connects it twice, and it is then called
-- twice. That is deliberate: deduplicating would make `disconnect` ambiguous
-- about which of the two it removed.
function signal.connect<T>(object: T, name: string, handler: Handler<T>)
  -- `create` is true, so the list is guaranteed to exist.
  local records: Records = assert(recordsFor(object, name, true))
  -- Pruned on every connect, so that a signal connected and dropped
  -- repeatedly does not grow a list of records whose handlers have gone.
  prune(records)
  records[#records + 1] = newRecord(handler, false)
end

-- Connects `handler` weakly: the registry does not keep it alive.
--
-- When nothing else references the handler it is collected, and the connection
-- goes with it. A panel connecting to a signal on something that outlives the
-- panel uses this, so that dropping the panel drops the connection rather than
-- leaving the panel reachable from a registry nobody is looking at.
--
-- The handler has to be referenced from somewhere, then. A closure written
-- directly into this call is unreachable the moment the call returns and may be
-- collected before it is ever invoked, so a caller stores it — usually on the
-- object it belongs to — and passes that.
function signal.weakConnect<T>(object: T, name: string, handler: Handler<T>)
  -- `create` is true, so the list is guaranteed to exist.
  local records: Records = assert(recordsFor(object, name, true))
  prune(records)
  records[#records + 1] = newRecord(handler, true)
end

-- Removes the first connection of `handler` to `name` on `object`.
--
-- Returns whether one was found. Disconnecting something that was never
-- connected is not an error: a teardown path that runs after the object has
-- already dropped its connections should not have to ask first.
function signal.disconnect<T>(object: T, name: string, handler: Handler<T>): boolean
  local records = recordsFor(object, name, false)
  if not records then
    return false
  end

  for index = 1, #records do
    if records[index].handler == handler then
      table.remove(records, index)
      return true
    end
  end
  return false
end

-- Removes every connection on `object`, on `name` alone when one is given.
function signal.disconnectAll(object: unknown, name: string?)
  local byName = connections[object]
  if not byName then
    return
  end
  if name == nil then
    connections[object] = nil
  else
    byName[name] = nil
  end
end

-- Calls every handler connected to `name` on `object`, as `handler(object,
-- ...)`.
--
-- Emitting a signal nothing is connected to does nothing, which is what makes a
-- signal cheap enough to emit unconditionally.
--
-- An error a handler raises propagates, per CONTRIBUTING.md's rule against
-- swallowing one to keep a frame alive. The remaining handlers do not run;
-- reporting and continuing is `lovr.errhand`'s job, at the callback boundary,
-- and doing it here as well would report the same error twice and hide which
-- handler stopped the emission.
function signal.emit(object: unknown, name: string, ...)
  local records = recordsFor(object, name, false)
  if not records then
    return
  end

  -- Snapshotted, because a handler is free to connect or disconnect while it
  -- runs and iterating the live list would then skip or repeat one. The
  -- snapshot is of this instant: a handler connected during the emission is
  -- not called by it.
  local handlers: { Handler<any> } = {}
  local count = 0
  for index = 1, #records do
    local handler = records[index].handler
    if handler then
      count = count + 1
      handlers[count] = handler
    end
  end

  for index = 1, count do
    handlers[index](object, ...)
  end
end

-- How many live connections `name` has on `object`.
--
-- Collected weak connections are not counted, and are pruned as a side effect
-- of the count. Written for the specs and for the reload check
-- CONTRIBUTING.md's teardown rule asks for, both of which need to assert that
-- nothing accumulated.
function signal.connectionCount(object: unknown, name: string): number
  local records = recordsFor(object, name, false)
  if not records then
    return 0
  end
  prune(records)
  return #records
end

-- Sets `object[key]` and emits `property::<key>` when the value changed.
--
-- This is the property-change mechanism: a setter calls this instead of
-- assigning, and every interested party hears about it without polling each
-- frame. The signal carries the new value and the old one, in that order.
--
-- A value equal to the one already there emits nothing and returns false, so a
-- setter called every frame with the same number is silent.
-- `object` is `any` rather than a type parameter: this reads and writes
-- `object[key]` for a key the caller names, which no parameterised shape
-- describes.
function signal.setProperty(object: any, key: string, value: any): boolean
  local name = signal.propertyName(key)
  local previous = object[key]
  if previous == value then
    return false
  end

  object[key] = value
  signal.emit(object, name, value, previous)
  return true
end

-- Discards every connection.
--
-- Registered below with `mullion.teardown`, so that a soft reload does not
-- leave the old state's handlers connected to objects the new one is about to
-- reach.
function signal.teardown(): ()
  connections = setmetatable({}, { __mode = 'k' })
end

-- A connection. Weak records hold their handler in a weak-valued table, so a
-- collected handler leaves a record whose `handler` is nil and which `prune`
-- then drops.
--
-- A weak-valued record rather than the weak-keyed table of handlers awesome
-- uses, because the records are an ordered list: handlers run in the order they
-- were connected, and a table keyed by handler has no order to run in.
function newRecord(handler: Handler<any>, weak: boolean): Record
  if type(handler) ~= 'function' then
    error('mullion.signal: a handler is a function, not a ' .. type(handler), 3)
  end
  local record: Record = { handler = handler }
  if weak then
    setmetatable(record, { __mode = 'v' })
  end
  return record
end

-- The record list for `name` on `object`, creating it when `create` is true.
function recordsFor(object: unknown, name: string, create: boolean): Records?
  if object == nil then
    error('mullion.signal: a signal is on an object, and nil is not one', 3)
  end
  if type(name) ~= 'string' then
    error('mullion.signal: a signal is named by a string, not a ' .. type(name), 3)
  end

  local byName = connections[object]
  if not byName then
    if not create then
      return nil
    end
    byName = {} :: ByName
    connections[object] = byName
  end

  local records = byName[name]
  if not records then
    if not create then
      return nil
    end
    records = {} :: Records
    byName[name] = records
  end
  return records
end

-- Drops records whose weakly-held handler has been collected, in place and in
-- order.
function prune(records: Records)
  local kept = 0
  for index = 1, #records do
    local record = records[index]
    if record.handler then
      kept = kept + 1
      records[kept] = record
    end
  end
  for index = #records, kept + 1, -1 do
    records[index] = nil
  end
end

-- Registered by name, so that a module body running a second time — which is
-- what a soft reload does — leaves one hook rather than two.
teardown.register('mullion.signal', signal.teardown)

return signal
