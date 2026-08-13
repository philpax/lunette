-- The `lunette` module as the type checker sees it. At runtime this is
-- registered by the host; for static checking it is a stub whose surface
-- matches what `require '@lunette'` returns. It intentionally does not run.
--
-- The source of truth for the API shape is the Rust registration surface;
-- this file is kept in step with it by hand until that surface generates the
-- definitions.

-- The two handles that carry pixels. A caller with one of these and no interest
-- in which — `mullion.panel` is the one in the tree — reads the fields both
-- have and calls `getTexture`, which is why that method names this as its
-- receiver on both: a method reached through a union has to have the same type
-- on either side of it, and a receiver is a parameter like any other.
--
-- Every other method here names its own handle, so the receiver is checked.
export type Textured = Window | Monitor

-- Which pointer button an event names. The runtime refuses anything else.
export type PointerButton = 'left' | 'right' | 'middle' | 'back' | 'forward'

-- Somewhere pixel input can be delivered. Discriminated on `domain`, which is
-- what says whether `window` or `monitor` names something: testing it is how a
-- caller reaches the handle behind a sink without a nil check that cannot fail.
type SinkFields = {
  read dead: boolean,
  -- The compositor's identifier for a window sink, and nothing for a host one.
  read id: number?,
  read pointer: (Sink, number, number, Seat?) -> boolean,
  read button: (Sink, PointerButton, boolean, Seat?) -> boolean,
  read leave: (Sink, Seat?) -> boolean,
  -- In surface pixels, and `scrollDiscrete` in wheel clicks. A client uses the
  -- difference to decide whether to scroll kinetically (docs/input.md).
  read scroll: (Sink, number, number, Seat?) -> boolean,
  read scrollDiscrete: (Sink, number, number, Seat?) -> boolean,
  read key: (Sink, number, boolean, Seat?) -> boolean,
  read typeText: (Sink, string, Seat?) -> boolean,
  read modifiers: (Sink, { string }, Seat?) -> boolean,
}

type WindowSink = { read domain: 'window', read window: Window, read monitor: nil }
type HostSink = { read domain: 'host', read window: nil, read monitor: Monitor? }

export type Sink = SinkFields & (WindowSink | HostSink)

export type Window = {
  dead: boolean,
  id: number,
  title: string?,
  appId: string?,
  width: number,
  height: number,
  opaque: boolean,
  -- What the client says it draws, as `wp_content_type_v1` reports it.
  contentType: 'none' | 'photo' | 'video' | 'game',
  sink: Sink?,
  -- `false` while the client is gone or has committed nothing, which is why
  -- neither is a plain `Texture?`: the runtime answers with a boolean rather
  -- than with nil.
  getTexture: (Textured) -> Texture | false,
  stabilize: (Window) -> Texture | false,
  close: (Window) -> boolean,
  resize: (Window, number, number) -> boolean,
  setFrameRate: (Window, number?) -> boolean,
  setProperty: (Window, string, boolean | number | string) -> boolean,
  getProperty: (Window, string) -> boolean | number | string | nil,
  properties: (Window) -> { [string]: boolean | number | string },
}

export type Monitor = {
  dead: boolean,
  id: string,
  name: string,
  mirrored: boolean,
  pending: boolean,
  width: number,
  height: number,
  x: number,
  y: number,
  logicalWidth: number,
  logicalHeight: number,
  sink: Sink,
  getTexture: (Textured) -> Texture | false,
  mirror: (Monitor) -> boolean,
  dismiss: (Monitor) -> boolean,
  setPaused: (Monitor, boolean) -> boolean,
}

export type Process = {
  id: number,
  alive: boolean,
  pid: number?,
  external: boolean,
}

export type Stroke = {
  keycode: number,
  modifiers: { string },
}

export type SeatOptions = {
  rules: string?,
  model: string?,
  layout: string?,
  variant: string?,
  options: string?,
  repeatDelay: number?,
  repeatRate: number?,
}

export type Seat = {
  dead: boolean,
  id: number,
  name: string,
  clipboardBridge: boolean,
  layouts: { string },
  modifiers: { string },
  destroy: (Seat) -> boolean,
  setModifiers: (Seat, { string }?) -> boolean,
  setFocus: (Seat, Sink?) -> boolean,
  setClipboardBridge: (Seat, boolean) -> boolean,
  symbolFor: (Seat, number, { string }?) -> number?,
  characterFor: (Seat, number, { string }?) -> string?,
  strokeFor: (Seat, string | number) -> Stroke?,
}

-- What `output:setMode` changes. Every field is optional: what is left out
-- keeps the value the output already has.
export type OutputMode = {
  width: number?,
  height: number?,
  scale: number?,
  refresh: number?,
}

-- What `lunette.newOutput` takes. The size is required, because there is no
-- previous mode to take it from and a client cannot lay out against an output
-- with no size.
export type OutputOptions = {
  width: number,
  height: number,
  scale: number?,
  refresh: number?,
}

export type Output = {
  dead: boolean,
  id: number,
  width: number,
  height: number,
  scale: number,
  refresh: number,
  setMode: (Output, OutputMode) -> boolean,
  destroy: (Output) -> boolean,
}

export type SpawnOptions = {
  argv: { string },
  cwd: string?,
  env: { [string]: string }?,
  output: Output?,
  xwayland: boolean?,
}

export type ClaimOptions = {
  window: Window,
  width: number,
  height: number,
  priority: number,
}

export type Claim = {
  dead: boolean,
  id: number,
  granted: boolean,
  -- The real LÖVR `Layer`, or `false` while the claim holds none. Never cached
  -- across frames: what it names goes away on revoke.
  layer: Layer | false,
  priority: number,
  -- The layer's size, which is the requested size quantised up a ladder, and
  -- nothing while the claim holds no layer.
  width: number?,
  height: number?,
  window: Window?,
  setPriority: (Claim, number) -> boolean,
  release: (Claim) -> boolean,
}

local lunette = {
  windows = function(): { Window }
    return {}
  end,
  spawn = function(_: SpawnOptions): Process
    return { id = 0, alive = false, pid = nil, external = false }
  end,
  newSeat = function(_: string, __: SeatOptions?): Seat
    local seat: Seat = {
      dead = false,
      id = 0,
      name = '',
      clipboardBridge = false,
      layouts = {},
      modifiers = {},
      destroy = function(_: Seat): boolean
        return false
      end,
      setModifiers = function(_: Seat, __: { string }?): boolean
        return false
      end,
      setFocus = function(_: Seat, __: Sink?): boolean
        return false
      end,
      setClipboardBridge = function(_: Seat, __: boolean): boolean
        return false
      end,
      symbolFor = function(_: Seat, __: number, ___: { string }?): number?
        return nil
      end,
      characterFor = function(_: Seat, __: number, ___: { string }?): string?
        return nil
      end,
      strokeFor = function(_: Seat, __: string | number): Stroke?
        return nil
      end,
    }
    return seat
  end,
  monitors = function(): { Monitor }
    return {}
  end,
  seats = function(): { Seat }
    return {}
  end,
  scaleSteps = function(): { number }
    return {}
  end,
  setSceneEnabled = function(_: boolean): ()
    return
  end,
  sceneEnabled = function(): boolean
    return true
  end,
  restart = function(): ()
    return
  end,
  reload = function(): (boolean, string?)
    return true, nil
  end,
  claimLayer = function(_: ClaimOptions): Claim
    local claim: Claim = {
      dead = false,
      id = 0,
      granted = false,
      layer = false,
      priority = 0,
      width = nil,
      height = nil,
      window = nil,
      setPriority = function(_: Claim, __: number): boolean
        return false
      end,
      release = function(_: Claim): boolean
        return false
      end,
    }
    return claim
  end,
  newOutput = function(_: OutputOptions): Output
    local output: Output = {
      dead = false,
      id = 0,
      width = 0,
      height = 0,
      scale = 1,
      refresh = 0,
      setMode = function(_: Output, __: OutputMode): boolean
        return false
      end,
      destroy = function(_: Output): boolean
        return false
      end,
    }
    return output
  end,
  outputs = function(): { Output }
    return {}
  end,
}

return lunette
