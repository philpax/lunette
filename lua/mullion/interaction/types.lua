-- The vocabulary the pointer protocol is written in: what a pointer is handed,
-- what it points at, and what it hands back.
--
-- Types and nothing else. It holds no state, registers no teardown hook, and
-- requires only `lunette`, so a module that needs to name one of these types
-- does not take a dependency on the tier that implements them (`mullion.panel`
-- is tier 1 and names `Surface` from here, while `mullion.interaction` is tier
-- 2 and drives one).
--
-- A method's receiver is a parameter, and parameters are contravariant, so an
-- implementer's method can answer the contract only when the two name the same
-- receiver type. The alternative is `any` on both sides, which typechecks and
-- checks nothing. A module that can name `Surface` can write
-- `raycast: (Surface, ...) -> ...` and keep the receiver checked.
--
-- `mullion.interaction` re-exports every type here, so `interaction.Surface`
-- and `interaction.Pointer` remain the names the rest of the tree and
-- docs/stdlib.md use.

local lunette = require '@lunette'

local types = {}

-- The shape of a tuning table.
export type Tuning = {
  reach: number,
  grabDeadZone: number,
  scrollScale: number,
  scrollDeadZone: number,
  reachScale: number,
  reachMinimum: number,
  reachMaximum: number,
  resizeMinimum: number,
  resizeMaximum: number,
  -- Which pointer button the trigger is, as the sink names one.
  button: lunette.PointerButton,
}

export type Input = {
  pose: Mat4?,
  origin: vector,
  direction: vector,
  trigger: boolean,
  grip: boolean,
  scrollX: number?,
  scrollY: number?,
  dt: number?,
}

-- Everything a pointer needs of the things it points at.
--
-- Every field is `read`, which lets a panel, a keyboard, and a configuration's
-- own object all satisfy one contract: Luau compares a read-write property
-- invariantly, so `pose: Mat4` would not satisfy `pose: Mat4?`, and a field a
-- surface does not carry at all would not satisfy an optional one. A read-only
-- property is compared covariantly, so either form satisfies it.
--
-- A method names `Surface` as its receiver, and an implementer names it too. A
-- receiver is a parameter and parameters are contravariant, so an implementer
-- writing its own type there could not answer this one; writing `any` on both
-- sides would typecheck and check nothing. Naming the contract is what keeps the
-- receiver checked, and is why these types are in a module a tier 1 implementer
-- can require.
type SurfaceFields = {
  read dead: boolean,
  read grabbable: boolean?,
  read pose: Mat4?,
  read width: number?,
  read height: number?,
  read sink: ((Surface) -> lunette.Sink?)?,
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  -- Optional, because a surface fixed in place has neither, and `beginGrab`
  -- refuses one that cannot be carried.
  read setPose: ((Surface, Mat4) -> ())?,
  -- Both dimensions are optional: a panel takes either and implies the other
  -- from its source's aspect, and a keyboard scales proportionally from the
  -- width and ignores the height.
  read setSize: ((Surface, number?, number?) -> ())?,
  read onHover: ((Surface, number?, number?, Pointer) -> ())?,
  read onLeave: ((Surface, Pointer) -> ())?,
  read onPress: ((Surface, number?, number?, Pointer) -> ())?,
  read onRelease: ((Surface, Pointer) -> ())?,
}

-- What a surface is over, when it is over anything. A panel carries a kind and
-- the handle that kind names; a keyboard or a button of a configuration's own
-- carries neither, which `kind: nil` records. Testing `kind` lets `storePose`
-- below reach a window's property store without asking the caller to promise
-- anything.
type WindowBacked = { read kind: 'window', read source: lunette.Window }
type MonitorBacked = { read kind: 'monitor', read source: lunette.Monitor }
type Unbacked = { read kind: nil }

export type Surface = SurfaceFields & (WindowBacked | MonitorBacked | Unbacked)

export type Grab = {
  offset: Mat4,
  base: Mat4,
  pushed: number,
  reach: number,
  x: number,
  y: number,
  z: number,
  moving: boolean,
}

export type Scaling = {
  partner: Pointer,
  separation: number,
  width: number,
}

export type Pointer = {
  seat: lunette.Seat?,
  tuning: Tuning,
  hovered: Surface?,
  hitX: number?,
  hitY: number?,
  distance: number?,
  grabbed: Surface?,
  grab: Grab?,
  scaling: Scaling?,
  gripped: boolean,
  pressed: boolean,
  pressedSink: lunette.Sink?,
  pressedSurface: Surface?,
  handPosition: { number }?,
  dead: boolean,
  update: (Pointer, Input, { Surface }) -> (),
  withdraw: (Pointer) -> (),
  destroy: (Pointer) -> boolean,
  hover: (Pointer, Surface?) -> (),
  setButton: (Pointer, boolean, lunette.Sink?, Surface?) -> (),
  focus: (Pointer, lunette.Sink?) -> (),
  beginGrab: (Pointer, Surface, Mat4?) -> boolean,
  scaleWith: (Pointer, Mat4?) -> (),
  push: (Pointer, number, number) -> (),
  dragTo: (Pointer, Mat4?) -> (),
  endGrab: (Pointer) -> boolean,
}

return types
