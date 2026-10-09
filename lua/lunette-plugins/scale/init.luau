-- Choosers use the compositor's scale ladder. See docs/dev/lua-api.md#frame-pacing-and-output-scale for options.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/scale'
local chooser = require '@lunette-plugins/scale/chooser'

export type Service = contract.Service
export type Chooser = contract.Chooser
export type Tuning = chooser.Tuning

local config = require '@lunette-plugins/scale/config'

export type IdealBase = config.IdealBase
export type Ideal = config.Ideal
export type Settings = config.Settings
export type Config = config.Config

local function build(_context: plugin.Context, settings: Settings): Service
  local steps = lunette.scaleSteps()
  local base = chooser.ideal(settings.tuning)
  local hook = settings.ideal
  local function wanted(distance: number): number
    return hook(distance, base)
  end
  return {
    newChooser = function(_self: Service): Chooser
      return chooser.new { steps = steps, tuning = settings.tuning, ideal = wanted }
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'scale',
  capability = contract.capability,
  schema = config,
  build = build,
}
