-- The arc layout provider: pure layout policy over the tags service.
--
-- `tuning` sets the default radius, angular step, total span, and centre that
-- a call's own options override.
local plugin = require '@lunette-plugin'
local layout = require '@lunette-contracts/layout'
local tags = require '@lunette-contracts/tags'
local build = require '@lunette-plugins/layout/arc/service'

export type Settings = build.Settings
export type Service = layout.ArcService

-- What a configuration gives: every option optional.
export type Config = {
  read tuning: layout.Options?,
}

return plugin.provider<<Config, Settings, Service>> {
  name = 'layout/arc',
  capability = layout.arc,
  requires = { tags = tags.capability },
  defaults = {
    tuning = {
      radius = 1.6,
      step = 0.55,
      span = math.pi * 1.2,
      center = { 0, 1.5, 0 },
    },
  },
  build = build,
}
