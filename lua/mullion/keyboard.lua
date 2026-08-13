-- A virtual keyboard, driven by the seat's own keymap.
--
-- docs/stdlib.md's tier 2, the last item on its minimum viable line: a keyboard
-- that can type into the focused sink. What is drawn on a key comes from
-- `seat:characterFor`, and what a key sends comes from the same keycode the
-- legend was read for. Nothing here holds a layout.
--
-- The rows come from `mullion.keycodes` and are physical, not linguistic: they
-- say where the keys are, and the seat says what they are. A table of legends
-- here would be a second and worse copy of something lunette already knows.
--
-- Modifiers are sticky. A user pointing at a keyboard with one laser cannot
-- hold shift and press a letter at the same time, so pressing shift latches it
-- and the next key clears it. `capsLock` locks instead, because that is what a
-- lock is.
--
-- Modifier state is set rather than synthesised: `sink:modifiers` replaces the
-- set held, as docs/input.md#keyboard describes, instead of sending a press of
-- a representative key. A client that queries the state is then not misled and
-- no key event is produced that nothing asked for.
--
-- The drawing is `Pass:plane` and `Pass:text` and nothing else. This sits on
-- the boundary of the widget toolkit docs/stdlib.md defers and docs/decisions.md
-- records as possibly a separate library, and it does not cross it.

local lunette = require '@lunette'

local interaction = require '@mullion/interaction'
local pointing = require '@mullion/interaction/types'
local keycodes = require '@mullion/keycodes'
local panel = require '@mullion/panel'
local signal = require '@mullion/signal'
local teardown = require '@mullion/teardown'

local keyboard = {}

-- Declared here and defined below the public API, so the file reads
-- surface-first. The metatable is a table rather than a forward-declared local
-- because `new` reads it before the methods below are filled in.
local methods = {}
local metatable = { __index = methods }
local extentOf, remove

-- Whoever is hovering, held only as an identity and never read: a pointer
-- hovers as itself, and a caller driving the keyboard by hand passes a name.
export type HoverSource = string | interaction.Pointer

export type Keyboard = {
  pose: Mat4,
  rows: { KeyRow },
  style: Style,
  target: () -> (lunette.Seat?, lunette.Sink?),
  width: number,
  height: number,
  visible: boolean,
  latched: { [string]: boolean },
  locked: { [string]: boolean },
  hovered: { [HoverSource]: RenderedKey? },
  grabbable: boolean,
  dead: boolean,
  -- The six the surface contract declares take its receiver.
  setPose: (pointing.Surface, Mat4) -> (),
  setSize: (pointing.Surface, number?, number?) -> (),
  raycast: (pointing.Surface, vector, vector, boolean?) -> (number?, number?, number?),
  onHover: (pointing.Surface, number?, number?, HoverSource?) -> (),
  onLeave: (pointing.Surface, HoverSource?) -> (),
  onPress: (pointing.Surface, number?, number?, unknown?) -> (),
  setHovered: (Keyboard, RenderedKey?, HoverSource?) -> (),
  isHovered: (Keyboard, number) -> boolean,
  setVisible: (Keyboard, boolean) -> (),
  modifiers: (Keyboard) -> { string },
  toggleModifier: (Keyboard, string) -> (),
  keys: (Keyboard) -> { RenderedKey },
  legendSeat: (Keyboard) -> lunette.Seat?,
  legendFor: (Keyboard, Key, lunette.Seat?, { string }) -> string,
  hit: (Keyboard, vector, vector, boolean?) -> (RenderedKey?, number?),
  pressKey: (Keyboard, number) -> boolean,
  typeText: (Keyboard, string) -> boolean,
  draw: (Keyboard, Pass) -> (),
  destroy: (Keyboard) -> boolean,
  isHeld: (Keyboard, { string }, string) -> boolean,
  clearLatched: (Keyboard, lunette.Seat?, lunette.Sink?) -> boolean,
}

-- A key in a row, matching `mullion.keycodes`'s `Key`.
type Key = {
  code: number,
  label: string?,
  width: number?,
}
-- A row of keys.
type KeyRow = { Key }
-- A key with its legend and calculated position.
type RenderedKey = {
  code: number,
  modifier: string?,
  legend: string,
  x: number,
  y: number,
  width: number,
  height: number,
}
-- Everything the look of a keyboard is tuned by. `typeof(keyboard.STYLE)`
-- would chase the values, so the shape is written out once.
type Style = {
  keyUnit: number,
  gap: number,
  plateDepth: number,
  legendDepth: number,
  margin: number,
  plateColor: { number },
  keyColor: { number },
  heldColor: { number },
  hoverColor: { number },
  legendColor: { number },
  legendHeight: number,
}
-- The seat and sink the keyboard types into, as `options.target` answers.
type Target = () -> (lunette.Seat?, lunette.Sink?)
-- The options `new` takes.
type KeyboardOptions = {
  rows: { KeyRow }?,
  style: Style?,
  pose: Mat4?,
  target: Target?,
}

-- Every live keyboard, in creation order. Rebuilt when this file runs, so a
-- soft reload starts with none.
local keyboards: { Keyboard } = {}

-- One UTF-8 character: a lead byte and its continuation bytes. LuaJIT is Lua
-- 5.1 and has no `utf8` library, and splitting text by byte would send half of
-- a character to `strokeFor`.
local CHARACTER = '[%z\1-\127\194-\244][\128-\191]*'

-- Everything the look of a keyboard is tuned by, in one table, for the same
-- reason the other tier-2 modules keep one.
keyboard.STYLE = {
  -- One key unit, in metres. Every width in the rows is a multiple of it, and
  -- the keyboard's size follows from it.
  keyUnit = 0.028,
  -- How much of a unit is left blank between two keys. Drawn only: a hit uses
  -- the whole cell, because a laser is not precise enough for a gap to be a
  -- miss.
  gap = 0.004,
  -- How far the backplate sits behind the keys, and the keys behind their
  -- legends, so that none of the three fights another for the same depth.
  plateDepth = 0.002,
  legendDepth = 0.001,
  -- How far the backplate extends past the outermost keys.
  margin = 0.008,
  plateColor = { 0.1, 0.1, 0.13, 0.92 },
  keyColor = { 0.2, 0.2, 0.24, 1 },
  -- What a latched or locked modifier key takes.
  heldColor = { 0.35, 0.55, 0.95, 1 },
  -- What the key under a pointer takes, so that aiming at one is visible
  -- before it is pressed.
  hoverColor = { 0.4, 0.42, 0.5, 1 },
  legendColor = { 1, 1, 1, 1 },
  legendHeight = 0.012,
}

-- A keyboard.
--
-- `options` takes `pose`, a `Mat4`; `rows`, defaulting to `keycodes.ROWS`;
-- `style`; and `target`, a function answering the seat and the sink to type
-- into. The default target is whatever was last clicked, which is what
-- `mullion.interaction` records for exactly this.
function keyboard.new(options: KeyboardOptions?): Keyboard
  local rows = (options and options.rows) or keycodes.ROWS
  local style = (options and options.style) or keyboard.STYLE

  local width, height = extentOf(rows, style)
  local pose = (options and options.pose) and lovr.math.newMat4(options.pose)
    or lovr.math.newMat4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1)
  -- Luau cannot verify that setmetatable produces a Keyboard because the
  -- methods are injected via __index rather than being on the table itself.
  -- Casting through any bridges this gap; every caller still gets full typing.
  local _raw: any = setmetatable({
    pose = pose,
    rows = rows,
    style = style,
    target = (options and options.target) or interaction.focused,
    -- The keyboard's size in metres, which the rows and the unit decide.
    width = width,
    height = height,
    visible = true,
    -- Latched modifiers clear after the next key; locked ones do not.
    latched = {},
    locked = {},
    -- The key each pointer is on, keyed by whatever the caller names it. Two
    -- hands aim at two keys, and one shared value would let whichever ran last
    -- erase the other's highlight.
    hovered = {},
    -- A keyboard is a surface, so a pointer may pick it up, push it, and resize
    -- it with the same grip that moves a panel.
    grabbable = true,
    dead = false,
  }, metatable)
  local created: Keyboard = _raw

  keyboards[#keyboards + 1] = created
  return created
end

-- Every live keyboard, in creation order, as a fresh table.
function keyboard.all(): { Keyboard }
  local live: { Keyboard } = {}
  for _, existing in ipairs(keyboards) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  return live
end

-- Draws every keyboard.
function keyboard.draw(pass: Pass): ()
  for _, existing in ipairs(keyboard.all()) do
    existing:draw(pass)
  end
end

-- Destroys every keyboard. Registered as this module's teardown hook: a reload
-- that left one behind would leave a keyboard floating in front of the user
-- with nothing left to type into.
function keyboard.teardown(): ()
  for _, existing in ipairs(keyboard.all()) do
    existing:destroy()
  end
  keyboards = {}
end

-- The key of `keys` that `x` and `y` fall inside, or nothing.
--
-- The coordinates run from the keyboard's top-left with y downwards, which is
-- what `panel.rayQuadHit` answers in.
function keyboard.keyAt(keys: { RenderedKey }, x: number, y: number): RenderedKey?
  for _, key in ipairs(keys) do
    if x >= key.x and x <= key.x + key.width and y >= key.y and y <= key.y + key.height then
      return key
    end
  end
  return nil
end

-- Moves the keyboard. `pose` is a `Mat4`, and is copied rather than kept.
function methods.setPose(self: Keyboard, pose: Mat4)
  self.pose:set(pose)
  signal.emit(self, signal.propertyName 'pose', self.pose)
end

-- Shows or hides the keyboard. A hidden one is neither drawn nor hit.
-- Marks the key a pointer is over, or nothing when it is over none.
--
-- Set each frame by whoever casts the ray. This module does not read a device,
-- so it cannot work out on its own which key is being aimed at.
--
-- `source` names the pointer, so that two hands each keep their own highlight.
-- Callers with one pointer may leave it off.
function methods.setHovered(self: Keyboard, entry: RenderedKey?, source: HoverSource?)
  self.hovered[source or 'default'] = entry
end

-- Whether any pointer is on the key with this code.
function methods.isHovered(self: Keyboard, code: number): boolean
  local hovered: { [HoverSource]: RenderedKey? } = self.hovered
  for _, entry in pairs(hovered) do
    if entry and entry.code == code then
      return true
    end
  end
  return false
end

function methods.setVisible(self: Keyboard, visible: boolean)
  signal.setProperty(self, 'visible', visible and true or false)
end

-- The modifiers held, as the array `sink:modifiers` takes.
--
-- In `keycodes.MODIFIER_ORDER` rather than in whatever order the tables were
-- walked in, so that what a client is told is the same for the same state.
function methods.modifiers(self: Keyboard): { string }
  local held: { string } = {}
  for _, name in ipairs(keycodes.MODIFIER_ORDER) do
    if self.latched[name] or self.locked[name] then
      held[#held + 1] = name
    end
  end
  return held
end

-- Latches a modifier, or turns a lock on or off.
function methods.toggleModifier(self: Keyboard, name: string)
  local locks: { [string]: boolean } = keycodes.LOCKS
  local isLock: boolean = type(locks[name]) == 'boolean'
  local set: { [string]: boolean } = isLock and self.locked :: { [string]: boolean }
    or self.latched :: { [string]: boolean }
  set[name] = not set[name] or nil
  signal.emit(self, 'modifiersChanged', self:modifiers())
end

-- Every key, with its legend and its place on the keyboard.
--
-- Fresh each call, and the legends are read from the seat each time, because
-- the legends depend on the modifiers held and those change under the user's
-- hands. A cached set would show the unshifted legends while shift was latched.
function methods.keys(self: Keyboard): { RenderedKey }
  local style: Style = self.style
  local unit: number = style.keyUnit
  local modifiers: { string } = self:modifiers()
  local seat: lunette.Seat? = self:legendSeat()

  local keys: { RenderedKey } = {}
  local y = 0
  for _, row in ipairs(self.rows) do
    local x = 0
    for _, entry: Key in ipairs(row) do
      local width = (entry.width or 1) * unit
      keys[#keys + 1] = {
        code = entry.code,
        modifier = keycodes.MODIFIERS[entry.code],
        legend = self:legendFor(entry, seat, modifiers),
        x = x,
        y = y,
        width = width,
        height = unit,
      }
      x = x + width
    end
    y = y + unit
  end
  return keys
end

-- What is drawn on a key.
--
-- The label wins, because a key that types a control character has nothing to
-- show. Otherwise the seat's own keymap answers, under the modifiers held. A
-- keysym with no text falls back to its number rather than to a blank: a key
-- with nothing on it looks broken, and the number at least says which.
-- The seat the legends are read from.
--
-- A legend is what a key would type, which only a seat's layout can say. The
-- target is whatever was last clicked, and nothing has been clicked when a
-- keyboard first appears, so the legends would be blank until the user typed
-- somewhere else first. Any seat answers the layout question, so an unfocused
-- keyboard borrows the first one rather than showing an unlabelled grid.
function methods.legendSeat(self: Keyboard): lunette.Seat?
  local seat: lunette.Seat?, _ = self.target()
  if seat then
    return seat
  end

  local seats = lunette.seats()
  return seats and seats[1] or nil
end

function methods.legendFor(self: Keyboard, entry: Key, seat: lunette.Seat?, modifiers: { string }): string
  if entry.label then
    return entry.label
  end
  if not seat then
    return ''
  end

  local text = seat:characterFor(entry.code, modifiers)
  if text and text ~= '' then
    return text
  end

  local symbol = seat:symbolFor(entry.code, modifiers)
  if symbol then
    return string.format('0x%x', symbol)
  end
  return ''
end

-- Where a ray meets this keyboard, in its own metres, and how far away that is.
--
-- The surface contract `mullion.interaction` picks against. A panel answers in
-- its source's pixels because that is what a sink takes; a keyboard has no
-- source, so it answers in the frame its key geometry is already in.
function methods.raycast(
  self: Keyboard,
  origin: vector,
  direction: vector,
  backFace: boolean?
): (number?, number?, number?)
  if self.dead or not self.visible then
    return nil, nil, nil
  end

  return panel.rayQuadHit({
    pose = self.pose,
    width = self.width,
    height = self.height,
    pixelWidth = self.width,
    pixelHeight = self.height,
  }, origin, direction)
end

-- Marks the key under a pointer. Part of the surface contract.
function methods.onHover(self: Keyboard, x: number?, y: number?, source: HoverSource?)
  if not x or not y then
    return
  end
  self:setHovered(keyboard.keyAt(self:keys(), x, y), source)
end

-- Clears this pointer's highlight when its ray moves off. Part of the surface
-- contract.
function methods.onLeave(self: Keyboard, source: HoverSource?)
  self:setHovered(nil, source)
end

-- Types the key under a pointer. Part of the surface contract.
function methods.onPress(self: Keyboard, x: number?, y: number?, _pointer: unknown?)
  if not x or not y then
    return
  end
  local entry = keyboard.keyAt(self:keys(), x, y)
  if entry then
    self:pressKey(entry.code)
  end
end

-- Resizes the keyboard, in metres, keeping its proportions.
--
-- The key unit is what every width in the rows is a multiple of, so scaling it
-- scales the geometry, the hit test, and the drawing together. Part of the
-- surface contract, which is what lets a two-handed grab size a keyboard the
-- way it sizes a panel.
function methods.setSize(self: Keyboard, width: number?, _height: number?)
  if not width or width <= 0 or self.width <= 0 then
    return
  end

  local scale = width / self.width
  local style: Style = {
    keyUnit = self.style.keyUnit,
    gap = self.style.gap,
    plateDepth = self.style.plateDepth,
    legendDepth = self.style.legendDepth,
    margin = self.style.margin,
    plateColor = self.style.plateColor,
    keyColor = self.style.keyColor,
    heldColor = self.style.heldColor,
    hoverColor = self.style.hoverColor,
    legendColor = self.style.legendColor,
    legendHeight = self.style.legendHeight,
  }
  style.keyUnit = self.style.keyUnit * scale
  style.gap = self.style.gap * scale
  style.margin = self.style.margin * scale
  style.plateDepth = self.style.plateDepth * scale
  style.legendDepth = self.style.legendDepth * scale
  style.legendHeight = self.style.legendHeight * scale

  self.style = style
  self.width, self.height = extentOf(self.rows, style)
end

-- The key a ray meets and how far away it is, or nothing.
--
-- The intersection is `panel.rayQuadHit`, the one raycaster the standard
-- library has. It answers in the source's pixels, so a keyboard hands it its
-- own size in metres as the pixel size: the "pixels" are then metres from the
-- top-left corner, which is the frame the key geometry is already in.
function methods.hit(self: Keyboard, origin: vector, direction: vector, backFace: boolean?): (RenderedKey?, number?)
  if self.dead or not self.visible then
    return nil, nil
  end

  local x, y, distance = panel.rayQuadHit({
    pose = self.pose,
    width = self.width,
    height = self.height,
    pixelWidth = self.width,
    pixelHeight = self.height,
    backFace = backFace,
  }, origin, direction)
  if not x or not y or not distance then
    return nil, nil
  end

  return keyboard.keyAt(self:keys(), x, y), distance
end

-- Presses and releases one key, reporting whether anything was sent.
--
-- A modifier key latches instead, and sends nothing: the modifiers ride with
-- the next key as a state, not as a press of their own.
function methods.pressKey(self: Keyboard, code: number)
  local modifier = keycodes.MODIFIERS[code]
  if modifier then
    self:toggleModifier(modifier)
    return true
  end

  local seat, sink = self.target()
  if not sink then
    return false
  end

  sink:modifiers(self:modifiers(), seat)
  sink:key(code, true, seat)
  sink:key(code, false, seat)
  self:clearLatched(seat, sink)
  return true
end

-- Types text, using the keymap where it can and `sink:typeText` where it
-- cannot.
--
-- Every character the layout binds goes down the ordinary path and changes
-- nothing about the client's keymap. A run of characters it does not bind goes
-- to `sink:typeText` in one call, which docs/lua-api.md describes as generating
-- a temporary keymap, uploading it, typing against it, and putting the client's
-- own back — so a call per character would swap the keymap once per character.
--
-- The two are not interleaved within one character. Each call is queued in
-- order and each `typeText` restores the keymap before the next command is
-- acted on, so a sequence alternating between them is well defined; what
-- docs/lua-api.md warns against is a key held down across one, which this never
-- does.
function methods.typeText(self: Keyboard, text: string)
  local seat, sink = self.target()
  if not sink then
    return false
  end
  local typedSink: lunette.Sink = sink
  -- With no seat there is no keymap to ask, so every character is text the
  -- layout cannot be shown to express.
  if not seat then
    return typedSink:typeText(text) and true
  end

  local pending: { string } = {}
  local function flush()
    if #pending > 0 then
      typedSink:typeText(table.concat(pending), seat)
      pending = {}
    end
  end

  for character in text:gmatch(CHARACTER) do
    local stroke = seat:strokeFor(character)
    if stroke then
      flush()
      typedSink:modifiers(stroke.modifiers, seat)
      typedSink:key(stroke.keycode, true, seat)
      typedSink:key(stroke.keycode, false, seat)
    else
      pending[#pending + 1] = character
    end
  end
  flush()

  -- The last stroke left its own modifiers held, and they belong to it rather
  -- than to whatever the user does next.
  typedSink:modifiers(self:modifiers(), seat)
  return true
end

-- Draws the backplate, the keys, and the legends.
function methods.draw(self: Keyboard, pass: Pass): ()
  if self.dead or not self.visible then
    return
  end

  local style: Style = self.style
  local width: number = self.width
  local height: number = self.height
  local color = style.plateColor
  pass:setColor(color[1], color[2], color[3], color[4])
  -- The extent rides in the transform's scale. `luax_readmat4` consumes a whole
  -- `Mat4` and reads the argument after it as the draw style, so a plane placed
  -- by matrix takes its size from that matrix and not from two more arguments.
  local plateTransform: Mat4 = lovr.math.newMat4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
  local pose: Mat4 = self.pose
  plateTransform:set(pose)
  plateTransform:translate(0, 0, -style.plateDepth)
  plateTransform:scale(width + style.margin * 2, height + style.margin * 2, 1)
  pass:plane(plateTransform, 'fill', 1, 1)

  local held = self:modifiers()
  for _, key: RenderedKey in ipairs(self:keys()) do
    local x = key.x + key.width / 2 - width / 2
    -- The key geometry runs from the top-left with y downwards, and the plane's
    -- own y runs upwards from its middle.
    local y = height / 2 - (key.y + key.height / 2)

    local keyColor = style.keyColor
    if key.modifier and self:isHeld(held, key.modifier) then
      keyColor = style.heldColor
    end
    -- After the held colour, so the key being aimed at reads as the one under
    -- consideration even when it is a modifier that is already down.
    if self:isHovered(key.code) then
      keyColor = style.hoverColor
    end
    pass:setColor(keyColor[1], keyColor[2], keyColor[3], keyColor[4])
    local keyTransform: Mat4 = lovr.math.newMat4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
    local keyPose: Mat4 = self.pose
    keyTransform:set(keyPose)
    keyTransform:translate(x, y, 0)
    keyTransform:scale(key.width - style.gap, key.height - style.gap, 1)
    pass:plane(keyTransform, 'fill', 1, 1)

    local legend = style.legendColor
    pass:setColor(legend[1], legend[2], legend[3], legend[4])
    local legendTransform: Mat4 = (function(): Mat4
      local lt: Mat4 = lovr.math.newMat4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
      local legendPose: Mat4 = self.pose
      lt:set(legendPose)
      lt:translate(x, y, style.legendDepth)
      lt:scale(vector.pack(style.legendHeight))
      return lt
    end)()
    pass:text(key.legend, legendTransform, 0, 'center', 'middle')
  end

  pass:setColor(1, 1, 1, 1)
end

-- Withdraws the keyboard and takes it out of the list.
function methods.destroy(self: Keyboard)
  if self.dead then
    return false
  end

  self.dead = true
  remove(self)
  signal.emit(self, 'destroyed')
  signal.disconnectAll(self)
  return true
end

-- Whether `name` is in a modifier array.
function methods.isHeld(self: Keyboard, held: { string }, name: string): boolean
  for _, modifier: string in ipairs(held) do
    if modifier == name then
      return true
    end
  end
  return false
end

-- Drops the latched modifiers after a key, and tells the client they went.
--
-- Nothing is sent when none were latched: a key pressed with no modifier
-- latched would otherwise send the same empty set twice.
function methods.clearLatched(self: Keyboard, seat: lunette.Seat?, sink: lunette.Sink?): boolean
  if not next(self.latched) then
    return false
  end

  self.latched = {}
  if sink then
    sink:modifiers(self:modifiers(), seat)
  end
  signal.emit(self, 'modifiersChanged', self:modifiers())
  return true
end

-- How large a set of rows is, in metres: as wide as the widest row and as tall
-- as the rows are deep.
function extentOf(rows: { KeyRow }, style: Style): (number, number)
  local widest = 0
  for _, row in ipairs(rows) do
    local width = 0
    for _, entry: Key in ipairs(row) do
      width = width + (entry.width or 1)
    end
    if width > widest then
      widest = width
    end
  end
  return widest * style.keyUnit, #rows * style.keyUnit
end

-- Takes a keyboard out of the list, so that a long session does not accumulate
-- dead entries.
function remove(destroyed: Keyboard)
  for index = 1, #keyboards do
    if keyboards[index] == destroyed then
      table.remove(keyboards, index)
      return
    end
  end
end

-- Registered by name, so that a module body running a second time — which is
-- what a soft reload does — leaves one hook rather than two.
teardown.register('mullion.keyboard', keyboard.teardown)

return keyboard
