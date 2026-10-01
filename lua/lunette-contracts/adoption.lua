-- Scoped window adoption, separate from installation of placement sources.
--
-- install registers only the native-state source. The adoption provider
-- registers it through its own rules binding, inside an effect on the caller's
-- owner, so the caller does not need to require rules and the source ends with
-- the caller. The caller installs rules, persisted state, and native state in
-- increasing precedence before start.
-- start subscribes before enumerating and skips windows already represented by
-- a live panel. Provider activation and windows never start adoption implicitly.
-- The caller effect owns subscriptions and panels created by start; disposing
-- it releases those resources without closing the native windows. An adopted
-- window's placement ends when its panel is removed, so the caller holds
-- nothing for a window that is gone.
--
-- placed answers every live adoption that any start made, in the order the
-- windows were placed, with the properties each was placed with. onPlaced
-- listeners hear each placement after the start caller's own onPlaced, so a
-- consumer other than the one that started adoption can react to placement
-- with the resolved properties. A listener is owner-scoped, runs under its
-- own protected call, and its error is reported through lunette.reportError
-- without undoing the placement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local rules = require '@lunette-contracts/rules'
local panels = require '@lunette-contracts/panels'

export type Owner = owner.Owner
export type Properties = rules.Resolved
export type Options = {
  read defaults: Properties?,
  read onPlaced: ((panels.WindowPanel, Properties) -> ())?,
}

-- A live adoption: the panel and the properties it was placed with.
export type Placement = {
  read panel: panels.WindowPanel,
  read properties: Properties,
}

export type PlacedListener = {
  read run: (panels.WindowPanel, Properties) -> (),
}

-- What install takes: the precedence its source is registered at, by default
-- PRECEDENCE.
export type InstallOptions = {
  read precedence: number?,
}

export type Service = {
  read SOURCE: string,
  read PRECEDENCE: number,
  read properties: (Service, lunette.Window) -> Properties?,
  read source: (Service) -> (lunette.Window) -> Properties?,
  read install: (Service, Owner, InstallOptions?) -> plugin.Effect,
  read windows: (Service) -> { lunette.Window },
  read start: (Service, Owner, Options?) -> plugin.Effect,
  read placed: (Service) -> { Placement },
  read onPlaced: (Service, Owner, PlacedListener) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

return {
  capability = plugin.capability<<Service>> { name = 'lunette/adoption', schema = 1 },
}
