-- Session plugin entry management. Inspection freezes copied containers, but callback, vector, and opaque custom
-- values keep their references.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
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

-- One entry of a recorded good composition: its configuration, and whether it was enabled.
export type GoodEntry = {
  read id: string,
  read config: unknown,
  read enabled: boolean,
}

-- The composition as it stood when a health policy last marked it good, in entry order. The runtime keeps the latest
-- mark in memory for the session; the policy that decides when a composition is healthy belongs to its caller.
export type GoodConfiguration = {
  read entries: { read [number]: GoodEntry },
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
  read ownerId: (Service, plugin.Owner) -> string?,
  read markGood: (Service) -> (),
  read lastGood: (Service) -> GoodConfiguration?,
}

composition.capability = plugin.capability<<Service>> { name = 'lunette/composition', version = 2 }

return composition
