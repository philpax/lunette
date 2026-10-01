-- The rules service contract.
--
-- Matching is pure policy, and resolve is a pure query: a source answers
-- without consuming anything. Source registration and placement acquire
-- caller-owned state. A source name names one registration, and registering a
-- name that is already registered raises. place answers the placement effect;
-- disposing it, or the owner unloading, removes the panel, its tag
-- memberships, and the tags placement created. A placement whose panel is
-- removed by other means ends with it.
--
-- Named match predicates receive the native field type, including nil for title
-- and appId. Unsupported match keys raise rather than matching an absent field.
-- Named properties accept literals or evaluators. Other keys preserve literal
-- values, including functions; dynamic extension values belong in evaluate.
-- evaluate is reserved metadata, merged per key in source order and omitted from
-- resolved output. A literal and evaluator for the same key in one source raise,
-- as does an extension evaluator naming a built-in property. This differs from
-- legacy rules, which implicitly invoked every function-valued extension.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local panels = require '@lunette-contracts/panels'
local tags = require '@lunette-contracts/tags'

local rules = {}

export type Owner = owner.Owner
export type Panel = panels.Panel
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
  read tags: { read [number]: string | Tag }?,
  [string]: unknown,
}

export type Predicate<T> = (T, lunette.Window) -> boolean
export type ContentType = 'none' | 'photo' | 'video' | 'game'
export type Match = {
  read dead: (boolean | Predicate<boolean>)?,
  read id: (number | Predicate<number>)?,
  read title: (string | Predicate<string?>)?,
  read appId: (string | Predicate<string?>)?,
  read width: (number | Predicate<number>)?,
  read height: (number | Predicate<number>)?,
  read opaque: (boolean | Predicate<boolean>)?,
  read contentType: (ContentType | Predicate<ContentType>)?,
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
  read PANEL_PROPERTIES: { string },
  read report: (Service, Report) -> (),
  read addSource: (Service, Owner, SourceRegistration) -> plugin.Effect,
  read sources: (Service) -> { Source },
  read fromList: (Service, { Rule }) -> (lunette.Window) -> Properties?,
  read setRules: (Service, Owner, RuleSet) -> plugin.Effect,
  read matches: (Service, Match?, lunette.Window) -> boolean,
  read resolve: (Service, lunette.Window) -> Resolved,
  read place: (Service, Owner, lunette.Window, Resolved?) -> (panels.WindowPanel, Resolved, plugin.Effect),
}

export type Capability = plugin.Capability<Service>

local capability = plugin.capability<<Service>> { name = 'lunette/rules', schema = 1 }

rules.capability = capability

return rules
