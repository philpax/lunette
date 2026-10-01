-- Scoped window adoption, separate from installation of placement sources.
--
-- install registers only the native-state source. The adoption provider
-- registers it through its own rules binding, inside an effect on the caller's
-- owner, so the caller does not need to require rules and the source ends with
-- the caller. The caller installs rules, persisted state, and native state in
-- increasing precedence before start.
-- start subscribes before enumerating and skips windows already represented by
-- a live panel. Provider activation and windows never start adoption implicitly.
-- The caller effect owns subscriptions and placements made by start; disposing
-- it releases those resources without closing the native windows. An adopted
-- window's placement ends when its panel is removed, so the caller holds
-- nothing for a window that is gone.
--
-- A window is adopted unless the start's filter answers false for it, or its
-- resolved properties, with the start's defaults beneath them, carry an
-- adopt of false. Such a window is left to whatever else wants it, such as a
-- plugin that draws a launcher itself. Adoption places a window through
-- lunette/placement, whose onPlaced announces it to every listener with its
-- resolved properties; the start's own onPlaced hears only that start's
-- placements, after the announcement.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local rules = require '@lunette-contracts/rules'
local panels = require '@lunette-contracts/panels'

export type Owner = owner.Owner
export type Properties = rules.Resolved
export type Options = {
  read defaults: Properties?,
  read filter: ((lunette.Window) -> boolean)?,
  read onPlaced: ((panels.WindowPanel, Properties) -> ())?,
}

-- What install takes: the precedence its source is registered at, by default
-- PRECEDENCE, which is vocabulary.PRECEDENCE.native unless configured.
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
}

export type Capability = plugin.Capability<Service>

return {
  capability = plugin.capability<<Service>> { name = 'lunette/adoption', schema = 1 },
}
