-- How often one window's client may draw: the rule a pacer applies.
--
-- `window:setFrameRate(hz)` is the mechanism and a pacer selects the rate. A window is exempt when its
-- content-type hint or its observed commit rate indicates video; docs/dev/rendering.md states the defaults.
-- The module is pure: a pacer receives what its caller observed and answers a rate.

local contract = require '@lunette-contracts/pacing'

local pacer = {}

export type ContentType = contract.ContentType
export type Observation = contract.Observation
export type Pacer = contract.Pacer

-- Which content types are exempt whatever the observed commit rate. Every
-- type is named, so a misspelt one is an unknown option rather than a type
-- that is never exempt.
export type ExemptTypes = {
  read none: boolean,
  read photo: boolean,
  read video: boolean,
  read game: boolean,
}

-- What a pacer is tuned by. `background` is the rate, in hertz, of a window out of view; `exempt` the rate of
-- an exempt window out of view; `history` how many commit observations are kept; `busy` the fraction of them
-- that must carry a commit to count as video; and `exemptTypes` the types exempt by their hint alone.
export type Tuning = {
  read background: number,
  read exempt: number,
  read history: number,
  read busy: number,
  read exemptTypes: ExemptTypes,
}

-- The rule that turns an observation into a rate, in hertz, or nil for
-- unthrottled. It receives the pacer, whose `isExempt` reads the history.
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

-- A pacer for one window. An empty history does not count as idle, so a new video player is not
-- throttled for its first second.
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

  -- A ring of the last `tuning.history` samples. A slot holds `false` for a frame with no commit, so an
  -- unfilled slot is distinguishable from a quiet one.
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

  -- Whether the samples taken so far, not the whole ring, show a client redrawing at close to full rate.
  local function isBusy(): boolean
    if seen == 0 then
      return false
    end
    return committed / seen >= tuning.busy
  end

  local self: Pacer
  self = table.freeze {
    -- Records one frame's observation and answers the rate and whether it changed. An observation with
    -- no `drew` adds no sample rather than counting as a quiet frame.
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
    -- The hint catches a video paused on a still frame; the commit rate catches a player that sets no hint.
    isExempt = function(_self: Pacer, contentType: ContentType?): boolean
      if contentType ~= nil and exemptTypes[contentType] then
        return true
      end
      return isBusy()
    end,
    -- For a window whose history no longer describes it, such as one whose
    -- client was replaced. A window that leaves the view keeps its history.
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

-- A rate a rule answered: nil for unthrottled, or a finite number of hertz
-- above zero, which is what `window:setFrameRate` accepts.
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
