-- The rules service contract: named, precedence-ordered sources that resolve a window's properties as a
-- pure query. Rules makes no panels and joins no tags; lunette/placement does. Unsupported match keys raise
-- rather than matching an absent field. See docs/dev/lua-api.md#rules-and-placement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local tags = require '@lunette-contracts/tags'
local vocabulary = require '@lunette-contracts/vocabulary'

local rules = {}

export type Owner = owner.Owner
export type Tag = tags.Tag

export type Valued<T> = T | ((lunette.Window, string) -> T)
export type Evaluators = { [string]: (lunette.Window, string) -> unknown }

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
  read tags: Valued<{ read [number]: string | Tag }>?,
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
  read tags: { read [number]: string | Tag }?,
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

export type Source = {
  read name: string,
  read precedence: number,
}

-- What addSource registers: a named resolver and the precedence it is merged
-- at. A higher precedence is merged later and wins a conflicting key.
export type SourceRegistration = {
  read name: string,
  read precedence: number,
  read resolve: (lunette.Window) -> Properties?,
}

-- What setRules registers: a rule list as a source. The name defaults to
-- DEFAULT_SOURCE and the precedence to DEFAULT_PRECEDENCE; a second list
-- registered at the same time needs a name of its own.
export type RuleSet = {
  read name: string?,
  read precedence: number?,
  read rules: { Rule },
}

export type LogLevel = 'debug' | 'info' | 'warn' | 'error'

-- What report logs. The level defaults to warn.
export type Report = {
  read message: string,
  read level: LogLevel?,
}

export type Service = {
  read DEFAULT_PRECEDENCE: number,
  read DEFAULT_SOURCE: string,
  read report: (Service, Report) -> (),
  read addSource: (Service, Owner, SourceRegistration) -> plugin.Effect,
  read sources: (Service) -> { Source },
  read fromList: (Service, { Rule }) -> (lunette.Window) -> Properties?,
  read setRules: (Service, Owner, RuleSet) -> plugin.Effect,
  read matches: (Service, Match?, lunette.Window) -> boolean,
  read resolve: (Service, lunette.Window) -> Resolved,
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/rules', schema = 1 }

rules.capability = capability

return rules
