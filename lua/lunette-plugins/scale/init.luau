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

local function validate(settings: Settings, name: string): ()
  local tuning = settings.tuning
  for _, option in ipairs { 'reference', 'nearest' } do
    local value = (tuning :: any)[option]
    if not (value > 0) or value == math.huge then
      error(
        'plugin ' .. name .. ': option tuning.' .. option .. ' is a distance in metres above zero, not ' .. value,
        0
      )
    end
  end
  if not (tuning.raise >= 0) or tuning.raise == math.huge then
    error('plugin ' .. name .. ': option tuning.raise is a fraction of zero or more, not ' .. tuning.raise, 0)
  end
  if not (tuning.lower >= 0 and tuning.lower < 1) then
    error('plugin ' .. name .. ': option tuning.lower is a fraction of at least 0 and below 1, not ' .. tuning.lower, 0)
  end
end

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
  validate = validate,
  build = build,
}
