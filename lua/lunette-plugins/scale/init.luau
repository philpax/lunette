-- Choosers use the compositor's scale ladder. See lua/lunette-plugins/scale/README.md for options.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/scale'
local chooser = require '@lunette-plugins/scale/chooser'
local config = require '@lunette-plugins/scale/config'

export type Service = contract.Service
export type Chooser = contract.Chooser
export type Tuning = chooser.Tuning
export type Settings = config.Settings
export type Config = config.Config

local function build(_context: plugin.Context, settings: Settings): Service
  local steps = lunette.scaleSteps()
  return {
    newChooser = function(_self: Service): Chooser
      return chooser.new(steps, settings.tuning)
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'scale',
  capability = contract.capability,
  schema = config.schema,
  build = build,
}
