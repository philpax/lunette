-- How often each window's client may draw.
--
-- A Wayland client cannot draw until the compositor answers its frame callback,
-- so this rate sets what a hidden panel costs. `window:setFrameRate(hz)` is the
-- mechanism; the per-window rate is policy, and the pacer selects it.
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
-- caller observed and answers with a rate. The specs run a panel through a
-- whole session without a clock, headset, or window.
--
-- The module starts nothing and holds no handle, so it registers no teardown
-- hook. Whatever made a pacer owns it, and a reload rebuilds it.

local pacing = {}

-- Everything the choice is tuned by, in one table.
--
-- Tuning is a diff to this table, as `mullion.scale.TUNING` and
-- `mullion.interaction.TUNING` are. A caller that needs different numbers for
-- one window passes its own table as `options.tuning` and leaves this one
-- unchanged.
pacing.TUNING = {
  -- The rate a window in view is paced at. `false` unthrottles it. The
  -- compositor already skips the blit for a surface that has not been damaged,
  -- so an idle foreground client costs nothing.
  foreground = false,
  -- The rate a window out of view is paced at, in hertz. The native floor is
  -- the cheapest rate at which a client keeps answering input.
  background = 1,
  -- The rate an exempt window out of view is paced at, in hertz. Low enough
  -- that throttling reduces the window's redraws, and high enough that a video
  -- does not visibly step.
  exempt = 30,
  -- How many of the recent samples this pacer keeps. At one sample a frame,
  -- this is about a second of history, a span long enough that a video between
  -- two frames of the same colour is not classified as idle.
  history = 90,
  -- The fraction of the recent samples that has to have carried a commit for
  -- a window to count as busy. A video player redraws on nearly every frame; a
  -- terminal with a blinking cursor redraws twice a second, well under this.
  busy = 0.5,
  -- The content types that are exempt regardless of the observed commit rate.
  -- 'game' has the same rationale as 'video': a paused game is still a window
  -- the user expects to resume without a stutter.
  exemptTypes = { video = true, game = true },
}

-- The shape of a tuning table, and of a pacer, for the locals that hold them.
type Tuning = typeof(pacing.TUNING)
-- The shape of what one frame observed.
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

-- Declared here and defined below the public API, so the file is ordered
-- surface-first.
local methods = {}
local metatable = { __index = methods }
local record, isBusy, isExempt
--
-- `options.tuning` replaces `pacing.TUNING` for this pacer.
--
-- The pacer starts with no observations, so its first choice uses the hint
-- alone. A newly opened window has no commit history; treating
-- an empty history as idle would throttle a video player for its first
-- second.
function pacing.newPacer(options: { tuning: Tuning? }?): Pacer
  local opts: { tuning: Tuning } = (options or {}) :: { tuning: Tuning }
  local tuning = opts.tuning or pacing.TUNING

  if type(tuning.history) ~= 'number' or tuning.history < 1 then
    error('mullion.pacing: a pacer keeps a history of at least one sample', 2)
  end

  -- Luau cannot verify that setmetatable produces a Pacer, because the methods
  -- arrive through `__index` and are not on the table itself. `mullion.scale`'s
  -- chooser uses the same shape, for the same reason.
  local _raw: any = setmetatable({
    tuning = tuning,
    -- How many of the last `tuning.history` samples carried a commit, and how
    -- many samples there have been. Because `samples` is a ring, a pacer
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
-- `state.visible` is whether the window is in view, and `state.contentType`
-- is `win.contentType`. `state.drew` is whether the client committed a new
-- buffer since the last call. A caller that cannot tell passes nothing, and
-- the pacer then uses the hint alone.
--
-- Returns the rate in hertz, or nil for unthrottled, and whether the rate
-- changed since the last observation. A caller can skip the
-- `window:setFrameRate` call when the rate did not change and pass the new
-- rate when it did. The tuning spells unthrottled as `false` because a table
-- cannot hold nil; the pacer returns nil for it.
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

-- The rate of this pacer's latest choice, or nil for unthrottled and for a
-- pacer with no observations.
function methods.current(self: Pacer): number?
  return self.chosen or nil
end

-- Whether this pacer currently counts its window as exempt from throttling.
--
-- Exposed for two reasons. A configuration that shows why a window is not
-- being throttled does not have to re-derive the rule. A caller that wants a
-- different exemption rule can compare its rule with the pacer's rule.
function methods.isExempt(self: Pacer, contentType: string): boolean
  return isExempt(self, contentType)
end

-- Discards the history and the settled rate.
--
-- For a window that moved, not one that left the view. A panel dragged
-- across the room keeps a history that no longer describes it.
function methods.reset(self: Pacer)
  self.samples = {} :: { boolean }
  self.next = 1
  self.committed = 0
  self.seen = 0
  self.chosen = nil
end

-- Adds one sample to the ring, evicting the oldest once it is full.
--
-- A slot holds `false` for a frame with no commit. A never-filled slot is
-- then distinguishable from one filled with a non-commit. Without that
-- distinction, the count of samples taken would drift.
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

-- Whether a window is exempt from throttling, by the content type hint or by
-- the observed commit rate.
--
-- Either condition is sufficient because each handles a case the other does
-- not. The hint applies to a video paused on a still frame, which produces
-- no commits. The commit rate applies to a player that sets no hint, and
-- most video players set no hint.
function isExempt(pacer: Pacer, contentType: string?)
  if pacer.tuning.exemptTypes[contentType] then
    return true
  end
  return isBusy(pacer)
end

-- Whether the recent samples show a client redrawing at close to full rate.
--
-- Measured against the samples actually taken, not the whole ring, so a
-- window open for three frames is judged on those three.
function isBusy(pacer: Pacer)
  if pacer.seen == 0 then
    return false
  end
  return pacer.committed / pacer.seen >= pacer.tuning.busy
end

return pacing
