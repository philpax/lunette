-- See docs/dev/lua-api.md#frame-pacing-and-output-scale for the pacing options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/pacing'
local pacer = require '@lunette-plugins/pacing/pacer'

export type Service = contract.Service
export type Pacer = contract.Pacer
export type Observation = contract.Observation
export type Tuning = pacer.Tuning

local config = require '@lunette-plugins/pacing/config'

export type ChooseBase = config.ChooseBase
export type Choose = config.Choose
export type Settings = config.Settings
export type Config = config.Config

local function validate(settings: Settings, name: string): ()
  local tuning = settings.tuning
  for _, option in ipairs { 'background', 'exempt' } do
    local value = (tuning :: any)[option]
    if not (value > 0) or value == math.huge then
      error('plugin ' .. name .. ': option tuning.' .. option .. ' is a rate in hertz above zero, not ' .. value, 0)
    end
  end
  if tuning.history < 1 or tuning.history ~= math.floor(tuning.history) then
    error('plugin ' .. name .. ': option tuning.history is a whole number of at least 1, not ' .. tuning.history, 0)
  end
  if not (tuning.busy > 0 and tuning.busy <= 1) then
    error('plugin ' .. name .. ': option tuning.busy is a fraction above 0 and at most 1, not ' .. tuning.busy, 0)
  end
end

local function build(_context: plugin.Context, settings: Settings): Service
  local base = pacer.rule(settings.tuning)
  local hook = settings.choose
  local function rule(paced: Pacer, observation: Observation): number?
    return hook(paced, observation, base)
  end
  return {
    newPacer = function(_self: Service): Pacer
      return pacer.new { tuning = settings.tuning, choose = rule }
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'pacing',
  capability = contract.capability,
  schema = config,
  validate = validate,
  build = build,
}
