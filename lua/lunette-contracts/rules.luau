-- Rules resolves window properties from named sources in precedence order. Unsupported match keys raise an error.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'

local rules = {}

export type Owner = plugin.Owner

export type Valued<T> = T | ((lunette.Window, string) -> T)
export type Evaluators = { read [string]: (lunette.Window, string) -> unknown }

export type Properties = {
  read pose: Valued<string | Mat4>?,
  read width: Valued<number>?,
  read height: Valued<number>?,
  read title: Valued<string>?,
  read priority: Valued<number>?,
  read chrome: Valued<boolean>?,
  read curve: Valued<number>?,
  read hidden: Valued<boolean>?,
  read adopt: Valued<boolean>?,
  read tags: Valued<{ read [number]: string }>?,
  read evaluate: Evaluators?,
  [string]: unknown,
}

export type Resolved = {
  read pose: (string | Mat4)?,
  read width: number?,
  read height: number?,
  read title: string?,
  read priority: number?,
  read chrome: boolean?,
  read curve: number?,
  read hidden: boolean?,
  read adopt: boolean?,
  read tags: { read [number]: string }?,
  [string]: unknown,
}

export type Predicate<T> = (T, lunette.Window) -> boolean
export type ContentType = vocabulary.ContentType
export type Match = {
  read dead: (boolean | Predicate<boolean>)?,
  read id: (number | Predicate<number>)?,
  read title: (string | Predicate<string?>)?,
  read appId: (string | Predicate<string?>)?,
  read width: (number | Predicate<number>)?,
  read height: (number | Predicate<number>)?,
  read opaque: (boolean | Predicate<boolean>)?,
  read contentType: (ContentType | Predicate<ContentType>)?,
  read where: ((lunette.Window) -> boolean)?,
  [string]: unknown,
}

export type Rule = {
  read match: Match?,
  read properties: Properties?,
}

-- Higher-precedence sources merge later and win on conflicting keys.
export type SourceRegistration = {
  read name: string,
  read precedence: number,
  read resolve: (lunette.Window) -> Properties?,
}

-- A rule set defaults to the source `lunette.rules` at the provider's precedence. Concurrent sets require distinct names.
export type RuleSet = {
  read name: string?,
  read precedence: number?,
  read rules: { read [number]: Rule },
}

local inspection = require '@lunette-contracts/inspection'

export type Service = {
  read inspect: (Service) -> inspection.Snapshot,
  read addSource: (Service, Owner, SourceRegistration) -> plugin.Effect,
  read setRules: (Service, Owner, RuleSet) -> plugin.Effect,
  read resolve: (Service, lunette.Window) -> Resolved,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/rules', schema = 1 }

rules.capability = capability

return rules
