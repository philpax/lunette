-- Themes are owner-scoped named registrations of complete themes. The catalog selects nothing; a selector applies a
-- chosen theme through `lunette/theme`.

local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'
local theme = require '@lunette-contracts/theme'

local themes = {}

export type Owner = plugin.Owner

-- `order` sorts choices before their names do and defaults to zero.
export type Registration = {
  read name: string,
  read label: string,
  read order: number?,
  read theme: theme.Theme,
}

export type Entry = {
  read name: string,
  read label: string,
  read order: number,
  read theme: theme.Theme,
}

export type ChangedListener = {
  read run: () -> (),
}

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read register: (Service, Owner, Registration) -> plugin.Effect,
  read list: (Service) -> { read [number]: Entry },
  read get: (Service, string) -> Entry?,
  read onChanged: (Service, Owner, ChangedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

themes.capability = plugin.capability<<Service>> { name = 'lunette/themes', schema = 1 }

return themes
