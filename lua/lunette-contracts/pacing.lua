-- The frame pacing contract.
--
-- A Wayland client draws only after the compositor answers its frame
-- callback, so how often each window is answered sets what it costs.
-- `window:setFrameRate` is the mechanism; which window gets which rate is
-- policy, and a pacer is where it is chosen. The service hands out pacers. A
-- pacer belongs to one window, receives what each frame observed about it,
-- and answers the rate to pace it at. It reads no clock, headset, or window
-- itself, and holds no native resource, so a pacer is not owner-scoped: it
-- is released with the last reference to it.
--
-- docs/dev/rendering.md states the two defaults a provider keeps. The floor
-- is approximately 1 Hz, which the native layer enforces. Video is exempt: a
-- window is exempt from throttling when its content-type hint or its observed
-- commit rate says it plays video.

local plugin = require '@lunette-plugin'

local pacing = {}

-- What `wp_content_type_v1` reports, as `window.contentType` carries it.
export type ContentType = 'none' | 'photo' | 'video' | 'game'

-- What one frame observed about a window. `visible` is whether the user can
-- see it; `contentType` is the window's hint; `drew` is whether the client
-- committed a new buffer since the previous observation, and is nil when the
-- caller cannot tell, such as while the window is throttled and its commits
-- show the throttle rather than what the client wants.
export type Observation = {
  read visible: boolean,
  read contentType: ContentType?,
  read drew: boolean?,
}

-- One window's pacer. `observe` records an observation and answers the rate
-- in hertz, or nil for unthrottled, and whether the rate differs from the
-- previous answer. `current` answers the latest rate. `isExempt` answers
-- whether a window with that hint, and this pacer's history, is exempt from
-- throttling. `reset` forgets the history and the latest rate.
export type Pacer = {
  read observe: (Pacer, Observation) -> (number?, boolean),
  read current: (Pacer) -> number?,
  read isExempt: (Pacer, ContentType?) -> boolean,
  read reset: (Pacer) -> (),
}

export type Service = {
  read newPacer: (Service) -> Pacer,
}

export type Capability = plugin.Capability<Service>

pacing.capability = plugin.capability<<Service>> { name = 'lunette/pacing', schema = 1 }

return pacing
