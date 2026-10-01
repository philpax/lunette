-- Recursive surface and pointer vocabulary shared by neutral contracts.
--
-- This module has no state and issues no capability. Keeping both sides of the
-- recursive relationship here lets surface.lua and interaction.lua remain
-- independently requireable without a runtime cycle. Constants that several
-- providers agree on also live here, so agreeing on one does not make a
-- provider require another's contract.

local lunette = require '@lunette'

local vocabulary = {}

-- The per-window property a window's kept pose is stored under. The
-- interaction provider writes it on a drop and the adoption provider reads it
-- as a placement source.
vocabulary.POSE_PROPERTY = 'mullion.pose'

export type Tuning = {
  read reach: number,
  read grabDeadZone: number,
  read scrollScale: number,
  read scrollDeadZone: number,
  read reachScale: number,
  read reachMinimum: number,
  read reachMaximum: number,
  read resizeMinimum: number,
  read resizeMaximum: number,
  read button: lunette.PointerButton,
}

export type Input = {
  read pose: Mat4?,
  read origin: vector,
  read direction: vector,
  read trigger: boolean,
  read grip: boolean,
  read scrollX: number?,
  read scrollY: number?,
  read dt: number?,
}

export type Grab = {
  read offset: Mat4,
  read base: Mat4,
  read pushed: number,
  read reach: number,
  read x: number,
  read y: number,
  read z: number,
  read moving: boolean,
}

export type Scaling = {
  read partner: Pointer,
  read separation: number,
  read width: number,
}

-- What Pointer:setButton takes: whether the button is held, and the sink and
-- surface it presses or releases on.
export type ButtonState = {
  read pressed: boolean,
  read sink: lunette.Sink?,
  read surface: Surface?,
}

-- What Pointer:push takes: the stick deflection that moves a grabbed surface
-- along the ray, and the frame time it is scaled by.
export type Push = {
  read deflection: number,
  read dt: number,
}

export type Pointer = {
  read seat: lunette.Seat?,
  read tuning: Tuning,
  read hovered: Surface?,
  read hitX: number?,
  read hitY: number?,
  read distance: number?,
  read grabbed: Surface?,
  read grab: Grab?,
  read scaling: Scaling?,
  read gripped: boolean,
  read pressed: boolean,
  read pressedSink: lunette.Sink?,
  read pressedSurface: Surface?,
  read handPosition: { number }?,
  read dead: boolean,
  read update: (Pointer, Input, { Surface }) -> (),
  read withdraw: (Pointer) -> (),
  read destroy: (Pointer) -> boolean,
  read hover: (Pointer, Surface?) -> (),
  read setButton: (Pointer, ButtonState) -> (),
  read focus: (Pointer, lunette.Sink?) -> (),
  read beginGrab: (Pointer, Surface, Mat4?) -> boolean,
  read scaleWith: (Pointer, Mat4?) -> (),
  read push: (Pointer, Push) -> (),
  read dragTo: (Pointer, Mat4?) -> (),
  read endGrab: (Pointer) -> boolean,
}

type SurfaceFields = {
  read dead: boolean,
  read grabbable: boolean?,
  read pose: Mat4?,
  read width: number?,
  read height: number?,
  read sink: ((Surface) -> lunette.Sink?)?,
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read setPose: ((Surface, Mat4) -> ())?,
  read setSize: ((Surface, number?, number?) -> ())?,
  read setHighlighted: ((Surface, boolean) -> ())?,
  read onHover: ((Surface, number?, number?, Pointer) -> ())?,
  read onLeave: ((Surface, Pointer) -> ())?,
  read onPress: ((Surface, number?, number?, Pointer) -> ())?,
  read onRelease: ((Surface, Pointer) -> ())?,
}

export type Surface =
  SurfaceFields
  & (
    { read kind: 'window', read source: lunette.Window }
    | { read kind: 'monitor', read source: lunette.Monitor }
    | { read kind: nil }
  )

return vocabulary
