-- See docs/dev/lua-api.md#frame-pacing-and-output-scale for the pacing options.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/pacing'
local pacer = require '@lunette-plugins/pacing/pacer'

export type Service = contract.Service
export type Pacer = contract.Pacer
export type Observation = contract.Observation
export type Tuning = pacer.Tuning

export type ChooseBase = (Pacer, Observation) -> number?
export type Choose = (Pacer, Observation, ChooseBase) -> number?

export type Settings = {
  read tuning: Tuning,
  read choose: Choose,
}

export type Config = {
  read tuning: {
    read background: number?,
    read exempt: number?,
    read history: number?,
    read busy: number?,
    read exemptTypes: {
      read none: boolean?,
      read photo: boolean?,
      read video: boolean?,
      read game: boolean?,
    }?,
  }?,
  read choose: Choose?,
}

local function choose(paced: Pacer, observation: Observation, base: ChooseBase): number?
  return base(paced, observation)
end

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
  defaults = {
    tuning = {
      -- The native floor: the cheapest rate at which a client keeps
      -- answering input.
      background = 1,
      -- Low enough that throttling reduces an exempt window's redraws, and
      -- high enough that a video does not visibly step.
      exempt = 30,
      -- About a second at one a frame, so a video between two same-coloured frames is not taken as idle.
      history = 90,
      -- A video player redraws on nearly every frame; a terminal with a
      -- blinking cursor redraws twice a second, well under half.
      busy = 0.5,
      -- A paused game, like a paused video, should resume without a stutter.
      exemptTypes = { none = false, photo = false, video = true, game = true },
    },
    choose = choose,
  },
  validate = validate,
  build = build,
}
