-- Recursive surface and pointer vocabulary, and constants and encodings several providers share, kept here
-- so neither side of a recursive relationship, nor any provider, must require another's contract.

local lunette = require '@lunette'

local vocabulary = {}

-- The per-window property a window's kept pose is stored under. The
-- desktop's pose memory writes it when a drop ends a grab, and the adoption
-- provider reads it as a placement source. Its value is `encodePose`'s string.
vocabulary.POSE_PROPERTY = 'lunette.pose'

-- The precedences the desktop's rules sources are registered at, by name. A higher precedence merges later
-- and wins. A configuration places its own source relative to these, as in `PRECEDENCE.persisted + 50`.
export type Precedences = {
  read rules: number,
  read persisted: number,
  read native: number,
}

local precedences: Precedences = table.freeze { rules = 100, persisted = 200, native = 300 }
vocabulary.PRECEDENCE = precedences

-- How many numbers a pose is written as.
--
-- The property store refuses tables, so the property store, a rule's textual `pose`, and a saved arrangement
-- share this string encoding. All sixteen elements are kept so a scale survives, and nine significant digits
-- make the 32-bit round trip exact.
vocabulary.POSE_ELEMENTS = 16

-- A `Mat4` as a string of sixteen numbers.
function vocabulary.encodePose(matrix: Mat4): string
  local elements: { number } = { matrix:unpack(true) }
  local encoded: { string } = {}
  for index = 1, vocabulary.POSE_ELEMENTS do
    encoded[index] = string.format('%.9g', elements[index])
  end
  return table.concat(encoded, ' ')
end

-- What `encodePose` wrote, as a fresh `Mat4`, or nothing for anything but sixteen finite numbers. A stored
-- value outlives the state that wrote it and may have been set by a configuration directly.
function vocabulary.decodePose(text: boolean | number | string | nil): Mat4?
  if type(text) ~= 'string' then
    return nil
  end
  local encoded: string = text

  local elements: { number } = {}
  local count = 0
  for word in encoded:gmatch '%S+' do
    count += 1
    if count > vocabulary.POSE_ELEMENTS then
      return nil
    end
    local number = tonumber(word)
    -- A non-finite element places a panel nowhere and would persist across reloads.
    if not number or number ~= number or number == math.huge or number == -math.huge then
      return nil
    end
    elements[count] = number
  end

  if count ~= vocabulary.POSE_ELEMENTS then
    return nil
  end
  return lovr.math.newMat4():set(
    elements[1],
    elements[2],
    elements[3],
    elements[4],
    elements[5],
    elements[6],
    elements[7],
    elements[8],
    elements[9],
    elements[10],
    elements[11],
    elements[12],
    elements[13],
    elements[14],
    elements[15],
    elements[16]
  )
end

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
}

-- The pointer buttons a pointer presses, in the order a pointer reports them.
vocabulary.POINTER_BUTTONS = table.freeze { 'left', 'right', 'middle', 'back', 'forward' } :: { lunette.PointerButton }

-- One frame of a pointing device: where it is, which way it points, which
-- pointer buttons are held, and whether it grips. A laser reads one per hand
-- and a pointer is driven by it. A button absent from `buttons` is up.
export type Input = {
  read pose: Mat4?,
  read origin: vector,
  read direction: vector,
  read buttons: { [lunette.PointerButton]: boolean },
  read grip: boolean,
  read scrollX: number?,
  read scrollY: number?,
  read dt: number?,
}

-- What Pointer:setButton takes: the button, `left` when none is named;
-- whether it is held; and the sink and surface it presses or releases on.
export type ButtonState = {
  read button: lunette.PointerButton?,
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

-- What Pointer:vibrate takes: the strength, from 0 to 1, and the duration in
-- seconds of one pulse on the device that drives the pointer.
export type Haptic = {
  read strength: number,
  read duration: number,
}

-- A pointer as its creator and the surfaces it reaches see it: what it
-- hovers and carries, read-only, and the primitives that drive it. Grab and
-- press bookkeeping belong to the provider.
export type Pointer = {
  read seat: lunette.Seat?,
  read tuning: Tuning,
  read hovered: Surface?,
  read hitX: number?,
  read hitY: number?,
  read distance: number?,
  read grabbed: Surface?,
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
  -- Pulses the device that drives the pointer, and answers whether a pulse
  -- was sent. A pointer whose creator gave it no device answers false.
  read vibrate: (Pointer, Haptic) -> boolean,
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

-- The fields of a surface whose `setPose` is required, restated because a generic alias of SurfaceFields is
-- refused for its recursion and an intersection would hold two `setPose` function types.
type MovableFields = {
  read dead: boolean,
  read grabbable: boolean?,
  read pose: Mat4?,
  read width: number?,
  read height: number?,
  read sink: ((Surface) -> lunette.Sink?)?,
  read raycast: (Surface, vector, vector, boolean?) -> (number?, number?, number?),
  read setPose: (Surface, Mat4) -> (),
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

-- A surface that can always be posed, such as a panel a layout arranges. It is stated whole rather than as
-- `Surface & { read setPose: ... }`, on which Luau reports `surface:setPose(pose)` as ambiguous.
export type Movable =
  MovableFields
  & (
    { read kind: 'window', read source: lunette.Window }
    | { read kind: 'monitor', read source: lunette.Monitor }
    | { read kind: nil }
  )

return vocabulary
