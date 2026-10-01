-- How often one window's client may draw: the rule a pacer applies.
--
-- A Wayland client cannot draw until the compositor answers its frame callback,
-- so this rate sets what a hidden panel costs. `window:setFrameRate(hz)` is the
-- mechanism; the per-window rate is policy, and a pacer selects it.
--
-- docs/dev/rendering.md states two defaults that are easy to get wrong. The floor
-- is approximately 1 Hz, not zero; the native layer enforces the floor, so a
-- rate below it is paced at the floor. Video is exempt: a throttled video
-- player stutters visibly, and the stutter costs more than the frames the
-- throttle would save.
--
-- `win.contentType` carries `wp_content_type_v1`, a hint with no events and
-- thin, uneven adoption: a client playing video may report 'none', and a
-- client reporting 'video' may show a paused frame. The hint is one input; the
-- observed commit rate is the other. A window is exempt when either input
-- indicates it. Trusting the hint alone would throttle every video player that
-- does not set it. Most video players set no hint.
--
-- The module reads no clock, headset, or window. A pacer receives what its
-- caller observed and answers with a rate, so the specs run a window through a
-- whole session without a clock, headset, or window. It starts nothing and
-- holds no handle: whatever made a pacer owns it, and a reload rebuilds it.

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

-- What a pacer is tuned by. `background` is the rate, in hertz, of a window
-- out of view; `exempt` the rate of an exempt window out of view; `history`
-- how many observations of commits are kept; `busy` the fraction of them that
-- carried a commit for a window to count as playing video; and `exemptTypes`
-- the content types exempt by their hint alone.
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

-- Declared here and defined below the public API, so the file is ordered
-- surface-first.
local checkRate

-- The default rule for a tuning: a window in view is unthrottled, an exempt
-- window out of view is paced at `exempt`, and any other window out of view at
-- `background`. A window in view is never throttled: the compositor already
-- skips the blit for a surface that has not been damaged, so an idle client
-- in view costs nothing.
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

-- A pacer for one window.
--
-- The pacer starts with no observations, so its first choice uses the hint
-- alone. A newly opened window has no commit history; treating an empty
-- history as idle would throttle a video player for its first second.
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

  -- How many of the last `tuning.history` samples carried a commit, and how
  -- many samples there have been. `samples` is a ring, so a pacer running for
  -- an hour holds the same memory as one running for a second. A slot holds
  -- `false` for a frame with no commit, so a never-filled slot is told from
  -- one filled with a non-commit, and the count of samples taken cannot drift.
  local samples: { boolean } = {}
  local nextSlot = 1
  local committed = 0
  local seen = 0
  local chosen: number? = nil
  local observed = false

  -- Adds one sample to the ring, evicting the oldest once it is full.
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

  -- Whether the recent samples show a client redrawing at close to full rate,
  -- judged on the samples actually taken rather than the whole ring, so a
  -- window open for three frames is judged on those three.
  local function isBusy(): boolean
    if seen == 0 then
      return false
    end
    return committed / seen >= tuning.busy
  end

  local self: Pacer
  self = table.freeze {
    -- Records what one frame observed and answers the rate this window should
    -- be paced at, and whether it changed since the previous answer, so a
    -- caller calls `window:setFrameRate` only when it did. An observation with
    -- no `drew` adds no sample: a caller that cannot tell whether the client
    -- drew says nothing about it rather than reporting a quiet frame.
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
    -- Either condition is sufficient because each handles a case the other
    -- does not. The hint applies to a video paused on a still frame, which
    -- produces no commits. The commit rate applies to a player that sets no
    -- hint, and most video players set no hint.
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
