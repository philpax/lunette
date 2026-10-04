-- Shared recursive types and constants avoid dependencies between provider contracts.

local lunette = require '@lunette'

local vocabulary = {}

-- `window.contentType` uses the values reported by `wp_content_type_v1`.
export type ContentType = 'none' | 'photo' | 'video' | 'game'

-- Persisted window poses use this property and the `encodePose` string format.
vocabulary.POSE_PROPERTY = 'lunette.pose'

-- Higher-precedence rule sources merge later and win. Configurations can place sources relative to these values.
export type Precedences = {
  read rules: number,
  read persisted: number,
  read native: number,
}

local precedences: Precedences = table.freeze { rules = 100, persisted = 200, native = 300 }
vocabulary.PRECEDENCE = precedences

-- Pose strings contain all sixteen matrix elements because the property store rejects tables and saved poses preserve scale. Nine significant digits preserve 32-bit float values exactly.
vocabulary.POSE_ELEMENTS = 16

function vocabulary.encodePose(matrix: Mat4): string
  local elements: { number } = { matrix:unpack(true) }
  local encoded: { string } = {}
  for index = 1, vocabulary.POSE_ELEMENTS do
    encoded[index] = string.format('%.9g', elements[index])
  end
  return table.concat(encoded, ' ')
end

-- The decoder returns nil unless the stored string contains exactly sixteen finite numbers.
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
    -- Non-finite values would place a panel unpredictably and persist across reloads.
    if not number or number ~= number or number == math.huge or number == -math.huge then
      return nil
    end
    elements[count] = number
  end

  if count ~= vocabulary.POSE_ELEMENTS then
    return nil
  end
  return lovr.math.newMat4():set(table.unpack(elements))
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

vocabulary.POINTER_BUTTONS = table.freeze { 'left', 'right', 'middle', 'back', 'forward' } :: { lunette.PointerButton }

-- A button absent from `buttons` is up.
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

-- The button defaults to `left` when omitted.
export type ButtonState = {
  read button: lunette.PointerButton?,
  read pressed: boolean,
  read sink: lunette.Sink?,
  read surface: Surface?,
}

export type Push = {
  read deflection: number,
  read dt: number,
}

-- Strength ranges from 0 to 1. Duration is measured in seconds.
export type Haptic = {
  read strength: number,
  read duration: number,
}

-- Grab and press bookkeeping remain private to the interaction provider.
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
  -- Returns false when the pointer has no device to pulse.
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

-- Luau rejects the recursive `SurfaceFields` alias and makes `setPose` ambiguous in an intersection.
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

-- `Movable` repeats the surface variants because Luau treats `surface:setPose(pose)` as ambiguous in an intersection with `Surface`.
export type Movable =
  MovableFields
  & (
    { read kind: 'window', read source: lunette.Window }
    | { read kind: 'monitor', read source: lunette.Monitor }
    | { read kind: nil }
  )

return vocabulary
