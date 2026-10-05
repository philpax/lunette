-- Consumers cannot use the published service after the provider activation ends.

local plugin = require '@lunette-plugin'
local clock = require './clock'

local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return plugin.provider<<Config, Settings, clock.Service>>({
  name = 'clock',
  capability = clock.capability,
  schema = descriptor,
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
}).definition
