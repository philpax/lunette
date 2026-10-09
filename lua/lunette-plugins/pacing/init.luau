-- See docs/dev/lua-api.md#frame-pacing-and-output-scale for the pacing options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/pacing'
local pacer = require '@lunette-plugins/pacing/pacer'
local config = require '@lunette-plugins/pacing/config'

export type Service = contract.Service
export type Settings = config.Settings
export type Config = config.Config

local function build(_context: plugin.Context, settings: Settings): Service
  return {
    newPacer = function(_self: Service): contract.Pacer
      return pacer.new(settings.tuning)
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'pacing',
  capability = contract.capability,
  schema = config.schema,
  build = build,
}
