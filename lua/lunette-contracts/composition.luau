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
  -- A protected entry cannot be changed at all; this includes a provider that a protected entry depends on unless the
  -- session names it reconfigurable. A required entry cannot be disabled or removed.
  read protected: boolean,
  read required: boolean,
  read diagnostic: string?,
  -- The configuration before saved settings, from the session's configuration file.
  read baseConfig: unknown,
  -- The entry's saved settings: the configuration fields the user changed, which take precedence over `baseConfig`.
  read saved: { read [string]: unknown }?,
}

-- Whether a saved field applies, fails its entry's schema, belongs to an entry that failed to start with its saved
-- fields, or belongs to an entry that is not composed.
export type SavedStatus = 'applied' | 'invalid' | 'suspended' | 'unused'

export type SavedSetting = {
  read id: string,
  read field: string,
  read value: unknown,
  read status: SavedStatus,
  read problem: string?,
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

-- A compact synchronous read. The revision changes when the observed entry order, configuration values, or enabled
-- intent differs from the previous read. Missing names include only contracts with no active provider, including children.
export type Observation = {
  read revision: number,
  -- Compact immutable values allow callers to compare their own samples when another caller observes between them.
  read entries: { read [number]: GoodEntry },
  read missing: { read [number]: string },
  read draining: boolean,
  read closing: boolean,
  read closed: boolean,
}

export type Service = {
  read observe: (Service, { read [number]: string }) -> Observation,
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
  -- Every saved field, by entry id and then field. Configuring an entry records the fields that differ from its base
  -- configuration as its saved settings.
  read savedSettings: (Service) -> { read [number]: SavedSetting },
  -- Removes one saved field of an entry, or all of them, and returns a composed entry to its base configuration with
  -- the saved fields that remain.
  read forgetSaved: (Service, string, string?) -> (),
  -- Returns every entry that runs with saved fields to its base configuration for the rest of the session, marking
  -- the fields suspended without removing them, and answers how many entries it returned. Protected entries and the
  -- providers they need keep running as they are.
  read suspendSaved: (Service) -> number,
}

composition.capability = plugin.capability<<Service>> { name = 'lunette/composition', version = 4 }

return composition
