-- The arrangement service contract: the desktop's saved arrangement, on demand. save refuses to write over a
-- file it could not read or one a newer version wrote unless forced; restore places live panels where the
-- arrangement has them.

local plugin = require '@lunette-plugin'

local arrangement = {}

-- Whether save can overwrite a file whose load failed.
export type SaveOptions = {
  read force: boolean?,
}

export type Service = {
  read save: (Service, SaveOptions?) -> (boolean, string?),
  read restore: (Service) -> number,
}

export type Capability = plugin.Capability<Service>

arrangement.capability = plugin.capability<<Service>> { name = 'lunette/arrangement', schema = 1 }

return arrangement
