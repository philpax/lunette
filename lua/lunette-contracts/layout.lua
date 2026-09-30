-- Pure layout contracts.
--
-- The arc module assigns poses and does not acquire or register resources.

local plugin = require '@lunette-plugin'
local surface = require '@lunette-contracts/surface'
local tags = require '@lunette-contracts/tags'

local layout = {}

export type Panel = tags.Panel
export type Target = { Panel } | tags.Tag

export type Options = {
  read radius: number?,
  read step: number?,
  read span: number?,
  read center: { number }?,
}

export type Tuning = {
  read radius: number,
  read step: number,
  read span: number,
  read center: { number },
}

export type ArcService = {
  read TUNING: Tuning,
  read angles: (ArcService, number, Options?) -> { number },
  read poses: (ArcService, number, Options?) -> { Mat4 },
  read apply: (ArcService, Target, Options?) -> { Panel },
  read __call: (ArcService, Target, Options?) -> { Panel },
}

export type Capability = plugin.Capability<ArcService>

local capability = plugin.capability('lunette/layout.arc', 1, function(value: ArcService): ArcService
  return value
end)

layout.arc = capability
layout.surface = surface

return layout
