-- The frame pacing provider: pacers built from `@lunette-plugins/pacing/pacer`.
--
-- Options: `tuning`, which `pacer.Tuning` describes, and `choose`, an around
-- hook. `choose(pacer, observation, base)` answers the rate a window is paced
-- at for one observation, in hertz or nil for unthrottled, and `base` is the
-- default rule: unthrottled in view, `tuning.exempt` for an exempt window out
-- of view, and `tuning.background` otherwise. A hook that paces a window in
-- view below full rate, or that exempts a window by its title, answers its
-- own rate and calls `base` for the rest. The provider requires nothing and
-- holds no resource, so a replacement is any plugin that provides
-- `lunette/pacing`.

local plugin = require '@lunette-plugin'
local contract = require '@lunette-contracts/pacing'
local pacer = require '@lunette-plugins/pacing/pacer'

export type Service = contract.Service
export type Pacer = contract.Pacer
export type Observation = contract.Observation
export type Tuning = pacer.Tuning

-- The default rule a `choose` hook receives as `base`.
export type ChooseBase = (Pacer, Observation) -> number?
export type Choose = (Pacer, Observation, ChooseBase) -> number?

-- The resolved options. Each activation receives its own frozen copy.
export type Settings = {
  read tuning: Tuning,
  read choose: Choose,
}

-- What a configuration gives: every option optional, and a tuning field
-- given alone merges over the rest.
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
      -- About a second of observations at one a frame, long enough that a
      -- video between two frames of the same colour is not classified as idle.
      history = 90,
      -- A video player redraws on nearly every frame; a terminal with a
      -- blinking cursor redraws twice a second, well under half.
      busy = 0.5,
      -- 'game' has the same rationale as 'video': a paused game is still a
      -- window the user expects to resume without a stutter.
      exemptTypes = { none = false, photo = false, video = true, game = true },
    },
    choose = choose,
  },
  validate = validate,
  build = build,
}
