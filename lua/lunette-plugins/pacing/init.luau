-- See docs/dev/lua-api.md#frame-pacing-and-output-scale for the pacing options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/pacing'
local pacer = require '@lunette-plugins/pacing/pacer'
local inspection = require '@lunette-contracts/inspection'

export type Service = contract.Service
export type Pacer = contract.Pacer
export type Observation = contract.Observation
export type Tuning = pacer.Tuning

local config = require '@lunette-plugins/pacing/config'

export type ChooseBase = config.ChooseBase
export type Choose = config.Choose
export type Settings = config.Settings
export type Config = config.Config

local function build(_context: plugin.Context, settings: Settings): Service
  local base = pacer.rule(settings.tuning)
  local hook = settings.choose
  local function rule(paced: Pacer, observation: Observation): number?
    return hook(paced, observation, base)
  end
  local created = 0
  return {
    inspect = function(_self: Service): inspection.Snapshot
      return inspection.snapshot({}, {
        createdPacers = created,
        background = settings.tuning.background,
        exempt = settings.tuning.exempt,
        history = settings.tuning.history,
        busy = settings.tuning.busy,
      }, { 'pacers have no owner or disposal registration', 'pacing observations are held by callers' })
    end,
    newPacer = function(_self: Service): Pacer
      local result = pacer.new { tuning = settings.tuning, choose = rule }
      created += 1
      return result
    end,
  }
end

return plugin.provider<<Config, Settings, Service>> {
  name = 'pacing',
  capability = contract.capability,
  schema = config,
  build = build,
}
