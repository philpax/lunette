-- The pacer selects a frame rate from window visibility, content type, and observed commits.
-- See docs/dev/rendering.md for the default rates.

local contract = require '@lunette-contracts/pacing'

local pacer = {}

export type ContentType = contract.ContentType
export type Observation = contract.Observation
export type Pacer = contract.Pacer

-- Content types that remain exempt regardless of observed commit rate.
export type ExemptTypes = {
  read none: boolean,
  read photo: boolean,
  read video: boolean,
  read game: boolean,
}

export type Tuning = {
  read background: number,
  read exempt: number,
  read history: number,
  read busy: number,
  read exemptTypes: ExemptTypes,
}

-- Returns a frame rate in hertz, or nil to leave the window unthrottled.
export type Choose = (Pacer, Observation) -> number?

-- What `new` takes. `choose` replaces the rule `pacer.rule` answers.
export type Options = {
  read tuning: Tuning,
  read choose: Choose?,
}

local checkRate

-- The default rule. A window in view is unthrottled, because the compositor already skips undamaged
-- surfaces; out of view, an exempt window runs at `exempt` and any other at `background`.
function pacer.rule(tuning: Tuning): Choose
  return function(paced: Pacer, observation: Observation): number?
    if observation.visible then
      return nil
    elseif paced:isExempt(observation.contentType) then
      return tuning.exempt
    end
    return tuning.background
  end
end

-- An empty history does not indicate idle content. New video players remain unthrottled until they have observations.
function pacer.new(options: Options): Pacer
  if type(options) ~= 'table' or type(options.tuning) ~= 'table' then
    error('pacing: a pacer is made from a table holding a tuning', 2)
  end
  local tuning = options.tuning
  if type(tuning.history) ~= 'number' or tuning.history < 1 or tuning.history ~= math.floor(tuning.history) then
    error('pacing: a pacer keeps a history of a whole number of at least one sample', 2)
  end
  local choose: Choose = options.choose or pacer.rule(tuning)
  local exemptTypes: { [string]: boolean } = (tuning.exemptTypes :: any) or {}

  -- Unfilled history slots differ from recorded frames without commits.
  local samples: { boolean } = {}
  local nextSlot = 1
  local committed = 0
  local seen = 0
  local chosen: number? = nil
  local observed = false

  local function record(drew: boolean): ()
    local evicted = samples[nextSlot]
    if evicted == nil then
      seen += 1
    elseif evicted then
      committed -= 1
    end
    samples[nextSlot] = drew
    if drew then
      committed += 1
    end
    nextSlot = nextSlot % tuning.history + 1
  end

  -- Unfilled history slots do not count as quiet samples.
  local function isBusy(): boolean
    if seen == 0 then
      return false
    end
    return committed / seen >= tuning.busy
  end

  local self: Pacer
  self = table.freeze {
    -- An observation without `drew` adds no sample because a throttled client cannot report a quiet frame.
    observe = function(_self: Pacer, observation: Observation): (number?, boolean)
      if type(observation) ~= 'table' then
        error('pacing: a pacer observes a table, not a ' .. type(observation), 2)
      end
      if type(observation.visible) ~= 'boolean' then
        error('pacing: an observation says whether the window is visible, not ' .. tostring(observation.visible), 2)
      end
      local drew = observation.drew
      if drew ~= nil then
        record(drew == true)
      end
      local rate = checkRate(choose(self, observation))
      local changed = not observed or rate ~= chosen
      observed = true
      chosen = rate
      return rate, changed
    end,
    current = function(_self: Pacer): number?
      return chosen
    end,
    -- The content hint identifies paused video; commit history identifies clients without a hint.
    isExempt = function(_self: Pacer, contentType: ContentType?): boolean
      if contentType ~= nil and exemptTypes[contentType] then
        return true
      end
      return isBusy()
    end,
    -- Reset history when a window's client changes. Visibility changes preserve it.
    reset = function(_self: Pacer): ()
      samples = {}
      nextSlot = 1
      committed = 0
      seen = 0
      chosen = nil
      observed = false
    end,
  }
  return self
end

function checkRate(rate: unknown): number?
  if rate == nil then
    return nil
  end
  if type(rate) ~= 'number' or not (rate > 0) or rate == math.huge then
    error('pacing: a rule answers a rate in hertz above zero or nil, not ' .. tostring(rate), 3)
  end
  return rate
end

return pacer
