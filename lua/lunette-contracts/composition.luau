-- Session plugin entry management. Inspection freezes copied containers, but callback, vector, and opaque custom
-- values keep their references.

local adapter = require '@lunette-plugin/adapter'
local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local composition = {}

export type Entry = {
  read id: string,
  read instanceId: string,
  read name: string,
  read config: unknown,
  read previousConfig: unknown,
  read schema: schema.Metadata?,
  read state: lunette.PluginState,
  read enabled: boolean,
  read protected: boolean,
  read diagnostic: string?,
}

-- The catalog keeps initial order and appends new ids. A removed or replaced entry keeps its position.
export type KnownEntry = {
  read id: string,
  read name: string,
  read installed: boolean,
  read schema: schema.Metadata?,
}

export type Service = {
  read entries: (Service) -> { Entry },
  read catalog: (Service) -> { read [number]: KnownEntry },
  read snapshot: (Service) -> lunette.PluginRuntimeSnapshot,
  read enable: (Service, string) -> (),
  read disable: (Service, string) -> (),
  read reload: (Service, string) -> (),
  read configure: (Service, string, unknown) -> (),
  read recover: (Service, string) -> (),
  read restore: (Service, string) -> (),
  read remove: (Service, string) -> (),
  read ownerId: (Service, adapter.Owner) -> string?,
}

composition.capability = adapter.capability<<Service>> { name = 'lunette/composition', schema = 1 }

return composition
