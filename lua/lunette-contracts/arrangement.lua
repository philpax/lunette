-- The arrangement service contract: the desktop's saved arrangement, on
-- demand.
--
-- The shipped provider is desktop/persistence, which also saves on every
-- drop and at quit. save captures every live panel's pose, size, and tags
-- and writes them, and answers whether it wrote and, when it did not, why;
-- it refuses to write over a file it could not read or one a newer version
-- wrote unless asked to force it. restore places the live panels where the
-- arrangement last loaded or saved has them, and answers how many it placed.
-- A key binding that saves, or one that puts the desktop back, uses this.

local plugin = require '@lunette-plugin'

local arrangement = {}

-- What save takes: whether to write over a file that was refused.
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
