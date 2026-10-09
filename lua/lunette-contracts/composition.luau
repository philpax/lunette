-- Session-only entry management validates configuration before changing runtime intent.
-- Reload enables the replacement and is nontransactional; activation failures remain visible in entries and snapshots.
-- Rejected reload requests leave configuration unchanged. Accepted requests retain configuration even if draining raises.
-- Recovery retains the last configuration that reached active state until restoration succeeds.
-- Inspection freezes copied containers, but callback, vector, and opaque custom values retain their references.
-- Editors must preserve opaque values and source-defined configuration rather than reconstructing them from editable fields.

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

-- Catalog entries expose session metadata without definitions, configuration, factories, or runtime handles.
-- The catalog keeps initial order and appends new ids; removal and source replacement retain the same position.
-- An uninstalled entry remains known, but restoration can still fail validation or activation.
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
  -- Restore uses only a known session definition and its last accepted configuration; it never resolves a module path.
  read restore: (Service, string) -> (),
  read remove: (Service, string) -> (),
  read ownerId: (Service, adapter.Owner) -> string?,
}

composition.capability = adapter.capability<<Service>> { name = 'lunette/composition', schema = 1 }

return composition
