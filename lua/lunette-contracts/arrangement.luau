-- The desktop's saved arrangement: pose, size, and tags, with panel properties in their own store.
-- `save` refuses to overwrite a file it could not read or one a newer version wrote. The saved shape and its version
-- are defined by `layout/persistence/private/format.luau`.

local plugin = require '@lunette-plugin'

local arrangement = {}

export type Service = {
  read save: (Service) -> (boolean, string?),
  read restore: (Service) -> number,
}

export type Capability = plugin.Capability<Service>

arrangement.capability = plugin.capability<<Service>> { name = 'lunette/arrangement', version = 1 }

return arrangement
