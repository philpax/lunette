-- How often each window's client is allowed to draw.
--
-- A Wayland client draws only after the compositor answers its frame callback,
-- so this module sets the cost of a panel that nobody is looking at.
-- `window:setFrameRate(hz)` is the mechanism, and choosing which window gets
-- which rate is the policy this module implements.
--
-- docs/rendering.md states the two defaults that are easy to get wrong. The
-- floor is approximately 1 Hz and not zero (the native layer enforces that, so
-- it paces a rate below the floor rather than honouring it). Video is exempt:
-- a throttled video player stutters conspicuously, which is worse than the
-- frames throttling would have saved.
--
-- Deciding what counts as video needs care. `win.contentType` carries
-- `wp_content_type_v1`, which is a hint with no events and thin, uneven
-- adoption: a client playing video may report 'none' and a client reporting
-- 'video' may be showing a paused frame. The hint is therefore one input and
-- the observed commit rate is the other, and a window is exempt when either
-- says so. Trusting the hint alone would throttle every video player that does
-- not set it, which is most of them.
--
-- Pure. Nothing here reads a clock, a headset, or a window; a pacer receives
-- what its caller observed and answers with a rate, so the specs drive a panel
-- through a whole session without one existing.
--
local pacing = {}

-- Everything the choice is tuned by, in one table.
--
-- Tuning is a diff to this table rather than a search through functions for a
-- number, as `mullion.scale.TUNING` and `mullion.interaction.TUNING` are.
pacing.TUNING = {
  -- The rate a window in view is paced at. `false` means unthrottled, which is
  -- what a panel the user is looking at should be: the compositor already skips
  -- the blit for a surface that has not been damaged, so an idle foreground
  -- client costs nothing to leave alone.
  foreground = false,
  -- The rate a window out of view is paced at, in hertz. At the native floor,
  -- because that is the cheapest a client can be made without it ceasing to
  -- answer input.
  background = 1,
  -- The rate an exempt window out of view is paced at, in hertz. Low enough to
  -- be worth doing and high enough that a video does not visibly step.
  exempt = 30,
  -- How many of the recent samples this pacer keeps. At a rate of one sample a
  -- frame this is about a second of history, which is long enough that a video
  -- between two frames of the same colour is not mistaken for an idle one.
  history = 90,
  -- The fraction of the recent samples that has to have carried a commit for a
  -- window to count as busy. A video player redraws on nearly every frame; a
  -- terminal with a blinking cursor redraws twice a second, which is well under
  -- this.
  busy = 0.5,
  -- The content types that are exempt whatever the commit rate says. 'game' is
  -- here for the reason 'video' is: a paused game is still a window the user
  -- expects to resume without a stutter.
  exemptTypes = { video = true, game = true },
}

-- The shape of a tuning table, and of a pacer, for the locals that hold them.
type Tuning = typeof(pacing.TUNING)
-- What one frame observed, as `observe` takes it.
export type Observation = {
  visible: boolean?,
  contentType: string?,
  drew: boolean?,
}

export type Pacer = {
  tuning: Tuning,
  samples: { boolean },
  next: number,
  committed: number,
  seen: number,
  chosen: number | false | nil,
  read observe: (Pacer, Observation) -> (number?, boolean),
  read current: (Pacer) -> number?,
  read isExempt: (Pacer, string) -> boolean,
  read reset: (Pacer) -> (),
}

local methods = {}
local metatable = { __index = methods }
local record, isBusy, isExempt
--
-- `options.tuning` replaces `pacing.TUNING` for this pacer.
--
-- The pacer starts having observed nothing, so its first choice is made on the
-- hint alone. That order is correct: a window that has just opened has no
-- commit history to judge it by, and treating no history as "not busy" would
-- throttle a video player for its first second.
function pacing.newPacer(options: { tuning: Tuning? }?): Pacer
  local opts: { tuning: Tuning } = (options or {}) :: { tuning: Tuning }
  local tuning = opts.tuning or pacing.TUNING

  if type(tuning.history) ~= 'number' or tuning.history < 1 then
    error('mullion.pacing: a pacer keeps a history of at least one sample', 2)
  end

  -- Luau cannot verify that setmetatable produces a Pacer, because the methods
  -- are injected through __index rather than being on the table itself. The
  -- same shape `mullion.scale`'s chooser has, for the same reason.
  local _raw: any = setmetatable({
    tuning = tuning,
    -- How many of the last `tuning.history` samples carried a commit, and how
    -- many samples there have been. A ring rather than a list, so a pacer
    -- running for an hour holds the same memory as one running for a second.
    samples = {},
    next = 1,
    committed = 0,
    seen = 0,
  }, metatable)
  return _raw
end

-- Records what one frame observed, and answers the rate this window should be
-- paced at.
--
-- `state.visible` is whether the window is in view, and `state.contentType` is
-- `win.contentType`. `state.drew` is whether the client committed a new buffer
-- since the last call; a caller that cannot tell passes nothing, and the pacer
-- then decides on the hint alone.
--
-- Returns the rate in hertz, or nil for unthrottled, and whether it changed,
-- so a caller can skip the `window:setFrameRate` when it did not, and pass the
-- rate straight on when it did. The tuning spells unthrottled as `false`
-- because a table cannot hold nil; what comes back out here is nil.
function methods.observe(self: Pacer, state: Observation)
  if type(state) ~= 'table' then
    error('mullion.pacing: a pacer observes a table, not a ' .. type(state), 2)
  end

  local drew: boolean? = state.drew
  record(self, drew)

  local chosen: number | false | nil
  if state.visible then
    chosen = self.tuning.foreground
  elseif isExempt(self, state.contentType) then
    chosen = self.tuning.exempt
  else
    chosen = self.tuning.background
  end

  local changed = chosen ~= self.chosen
  self.chosen = chosen
  return chosen or nil, changed
end

-- The rate this pacer last chose, or nil for unthrottled and before the first
-- observation.
function methods.current(self: Pacer): number?
  return self.chosen or nil
end

-- Whether this pacer currently counts its window as exempt from throttling.
--
-- Exposed so a configuration can inspect the exemption decision.
function methods.isExempt(self: Pacer, contentType: string): boolean
  return isExempt(self, contentType)
end

-- Forgets the history and the settled rate.
--
-- For a window that was moved rather than looked away from: a panel dragged
-- across the room carries a history describing where it used to be.
function methods.reset(self: Pacer)
  self.samples = {} :: { boolean }
  self.next = 1
  self.committed = 0
  self.seen = 0
  self.chosen = nil
end

-- Adds one sample to the ring, evicting the oldest once it is full.
--
-- A slot holds `false` rather than nil for a frame that carried no commit, so
-- that a slot never filled is distinguishable from one filled with a
-- non-commit. Without that the count of samples taken would drift.
function record(pacer: Pacer, drew: boolean | nil)
  local slot = pacer.next
  local evicted = pacer.samples[slot]

  if evicted == nil then
    pacer.seen = pacer.seen + 1
  elseif evicted then
    pacer.committed = pacer.committed - 1
  end

  pacer.samples[slot] = drew and true or false
  if drew then
    pacer.committed = pacer.committed + 1
  end

  pacer.next = slot % pacer.tuning.history + 1
end

-- Whether a window is exempt from throttling: the hint says so, or what was
-- observed does.
--
-- Either rather than both, because each covers the other's blind spot. The hint
-- catches a video that is paused on a still frame, which commits nothing; the
-- commit rate catches a player that sets no hint at all, which is most of them.
function isExempt(pacer: Pacer, contentType: string?)
  if pacer.tuning.exemptTypes[contentType] then
    return true
  end
  return isBusy(pacer)
end

-- Whether the recent samples show a client redrawing at close to full rate.
--
-- Measured against the samples actually taken rather than the whole ring, so a
-- window open for three frames is judged on those three.
function isBusy(pacer: Pacer)
  if pacer.seen == 0 then
    return false
  end
  return pacer.committed / pacer.seen >= pacer.tuning.busy
end

return pacing
