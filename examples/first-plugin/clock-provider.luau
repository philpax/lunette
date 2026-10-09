-- Consumers cannot use the published service after the provider activation ends.

local plugin = require '@lunette-plugin'
local clock = require './clock'

export type Config = {}
export type Settings = {}

return plugin.provider<<Config, Settings, clock.Service>> {
  name = 'clock',
  capability = clock.capability,
  build = function(_context: plugin.Context, _settings: Settings): clock.Service
    local started = lovr.timer.getTime()
    return {
      now = function(_self: clock.Service): number
        return lovr.timer.getTime()
      end,
      elapsed = function(_self: clock.Service): number
        return lovr.timer.getTime() - started
      end,
    }
  end,
}
