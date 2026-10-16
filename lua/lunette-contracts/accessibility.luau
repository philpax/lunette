-- Accessibility: the session's accessibility settings, which the toolkit, the theme, and the interaction service
-- consume, and announcements for assistive plugins.

local plugin = require '@lunette-plugin'
local vocabulary = require '@lunette-contracts/vocabulary'
local inspection = require '@lunette-contracts/inspection'

local accessibility = {}

export type Owner = plugin.Owner

export type Settings = {
  -- Motion uses substitutes: hover lift and press travel snap, and panels that follow move without easing.
  read reducedMotion: boolean,
  -- Multiplies every typography role's size, from 0.5 to 2.
  read textScale: number,
  -- Selects the theme's high-contrast variant.
  read highContrast: boolean,
  -- Multiplies hold, tooltip, and toast durations.
  read timing: number,
  read haptics: boolean,
  read sounds: boolean,
  read handedness: 'left' | 'right',
}

export type Politeness = 'polite' | 'assertive'

export type Announcement = {
  read text: string,
  read politeness: Politeness,
}

export type Listener = { read run: (Announcement) -> () }

export type Service = {
  read settings: vocabulary.Store<Settings>,
  -- Changes some settings, keeping the rest, and saves them.
  read update: (Service, { [string]: any }) -> (),
  -- Posts an announcement, such as a notification, for assistive plugins.
  read announce: (Service, Owner, Announcement) -> (),
  read onAnnouncement: (Service, Owner, Listener) -> plugin.Effect,
  read inspect: (Service) -> inspection.Snapshot,
}

export type Capability = plugin.Capability<Service>

accessibility.capability = plugin.capability<<Service>> { name = 'lunette/accessibility', version = 1 }

accessibility.DEFAULTS = table.freeze {
  reducedMotion = false,
  textScale = 1,
  highContrast = false,
  timing = 1,
  haptics = true,
  sounds = true,
  handedness = 'right',
} :: Settings

return accessibility
