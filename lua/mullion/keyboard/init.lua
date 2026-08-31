-- A virtual keyboard, using the seat's own keymap.
--
-- The keyboard is docs/dev/stdlib.md's tier 2, the last item on its minimum
-- viable line. It can type into the focused sink. What is drawn on a key
-- comes from `seat:characterFor`, and what a key sends comes from the same
-- keycode the legend is read for. The module stores no layout.
--
-- The rows come from `mullion.keycodes` and are physical. They place the
-- keys; the seat assigns what each key is. A table of legends here would be
-- a second copy of data lunette already holds.
--
-- Modifiers are sticky. A user pointing at a keyboard with one laser cannot
-- hold shift and press a letter at the same time. Pressing shift latches it,
-- and the next key clears it. `capsLock` locks, and `keycodes.LOCKS` marks it
-- as a lock.
--
-- Modifier state replaces the held set: `sink:modifiers` sets it, as
-- docs/dev/input.md#keyboard describes, and no key event is sent. A client that
-- queries the state reads the set the sink holds.
--
-- The drawing uses `Pass:plane` and `Pass:text`. It does not include the
-- widget toolkit that docs/dev/stdlib.md defers and records as possibly a
-- separate library.

local lunette = require '@lunette'

local interaction = require '@mullion/interaction'
local pointing = require '@mullion/interaction/types'
local keycodes = require '@mullion/keycodes'
local drawing = require '@mullion/keyboard/draw'
local layout = require '@mullion/keyboard/layout'
local panel = require '@mullion/panel'
local signal = require '@mullion/signal'
local teardown = require '@mullion/teardown'

local keyboard = {}

-- The metatable is created before the methods are filled in, and `__index`
-- resolves them at lookup time.
local methods = {}
local metatable = { __index = methods }
local remove

-- Whoever is hovering, held as an identity and never read. A pointer hovers
-- as itself; a caller without a pointer passes a name.
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
  -- The six surface-contract methods take the surface as their receiver.
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

-- Re-exported from `mullion.keyboard.layout`, which defines the geometry. A
-- caller has one name for each type.
export type Key = layout.Key
export type KeyRow = layout.KeyRow
export type RenderedKey = layout.RenderedKey
-- The values that tune the look of a keyboard. The shape is written out once;
-- `typeof(keyboard.STYLE)` would derive it from the values.
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
-- The seat and the sink the keyboard types into, as `options.target` answers.
type Target = () -> (lunette.Seat?, lunette.Sink?)
-- The options `new` takes.
type KeyboardOptions = {
  rows: { KeyRow }?,
  style: Style?,
  pose: Mat4?,
  target: Target?,
}

-- Every live keyboard, in creation order. Rebuilt at module load, so a soft
-- reload starts with none.
local keyboards: { Keyboard } = {}

-- One UTF-8 character: a lead byte and its continuation bytes. LuaJIT is Lua
-- 5.1 and has no `utf8` library, and splitting text by byte would send half of
-- a character to `strokeFor`.
local CHARACTER = '[%z\1-\127\194-\244][\128-\191]*'

-- The values that tune the look of a keyboard, in one table, as the other
-- tier-2 modules keep theirs.
keyboard.STYLE = {
  -- One key unit, in metres. Every row width is a multiple of it, and the
  -- keyboard's size derives from it.
  keyUnit = 0.028,
  -- How much of a unit is left blank between two keys. Applies to drawing. A
  -- hit test uses the whole cell, because a laser is not precise enough for
  -- a gap to count as a miss.
  gap = 0.004,
  -- Distance of the backplate behind the keys, and of the keys behind their
  -- legends. Each of the three layers keeps its own depth.
  plateDepth = 0.002,
  legendDepth = 0.001,
  -- How far the backplate extends past the outermost keys.
  margin = 0.008,
  plateColor = { 0.1, 0.1, 0.13, 0.92 },
  keyColor = { 0.2, 0.2, 0.24, 1 },
  -- Color of a latched or locked modifier key.
  heldColor = { 0.35, 0.55, 0.95, 1 },
  -- Color of the key under a pointer. The aim is visible before the press.
  hoverColor = { 0.4, 0.42, 0.5, 1 },
  legendColor = { 1, 1, 1, 1 },
  legendHeight = 0.012,
}

-- A keyboard. `options` takes `pose` as a `Mat4`; `rows`, which default to
-- `keycodes.ROWS`; `style`; and `target`, a function that answers the seat and
-- the sink to type into. The default target is the seat and the sink that
-- `mullion.interaction` last focused.
--
-- `target` takes no arguments and is not called as a method. It answers where
-- the text goes, which does not depend on which keyboard calls it. The default,
-- `interaction.focused`, is the shape every other target follows.
function keyboard.new(options: KeyboardOptions?): Keyboard
  local rows = (options and options.rows) or keycodes.ROWS
  local style = (options and options.style) or keyboard.STYLE

  local width, height = layout.extentOf(rows, style)
  local pose = (options and options.pose) and lovr.math.newMat4(options.pose) or lovr.math.newMat4()
  -- Luau cannot prove that setmetatable produces a Keyboard, because the
  -- methods arrive through __index and are not on the table itself. The
  -- cast through any keeps full typing for callers.
  local _raw: any = setmetatable({
    pose = pose,
    rows = rows,
    style = style,
    target = (options and options.target) or interaction.focused,
    -- The keyboard's size in metres, derived from the rows and the unit.
    width = width,
    height = height,
    visible = true,
    -- Latched modifiers clear after the next key; locked ones do not.
    latched = {},
    locked = {},
    -- The key each pointer is on, keyed by whatever name the caller gives.
    -- Two hands aim at two keys. A shared value would hold one entry, and the
    -- later write would replace the earlier highlight.
    hovered = {},
    -- A keyboard is a surface, so a pointer can grab, move, and resize it the
    -- same way it does a panel.
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

-- Destroys every keyboard. This module's teardown hook. A reload that leaves
-- a keyboard behind would leave one in front of the user with nothing to type
-- into.
function keyboard.teardown(): ()
  for _, existing in ipairs(keyboard.all()) do
    existing:destroy()
  end
  keyboards = {}
end

-- The key of `keys` that `x` and `y` fall inside, or nothing.
--
-- `mullion.keyboard.layout` defines it, and this is the name it is documented
-- under.
keyboard.keyAt = layout.keyAt

-- Moves the keyboard. `pose` is a `Mat4`; the method copies it.
function methods.setPose(self: Keyboard, pose: Mat4)
  self.pose:set(pose)
  signal.emit(self, signal.propertyName 'pose', self.pose)
end

-- Marks the key a pointer is over, or nothing when it is over none.
--
-- Each frame, whoever casts the ray sets it. This module does not read a
-- device, so it cannot determine which key is being aimed at.
--
-- `source` names the pointer, so two hands each keep their own highlight.
-- A caller with one pointer may leave it off.
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

-- Shows or hides the keyboard. A hidden one is neither drawn nor hit.
function methods.setVisible(self: Keyboard, visible: boolean)
  signal.setProperty(self, 'visible', visible and true or false)
end

-- The modifiers held, as the array `sink:modifiers` takes.
--
-- They are ordered by `keycodes.MODIFIER_ORDER`; the client receives the
-- same order for the same state, regardless of the order the tables are
-- walked in.
function methods.modifiers(self: Keyboard): { string }
  local held: { string } = {}
  for _, name in ipairs(keycodes.MODIFIER_ORDER) do
    if self.latched[name] or self.locked[name] then
      held[#held + 1] = name
    end
  end
  return held
end

-- Toggles a modifier: latches it, or turns a lock on and off.
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
-- the legends depend on the modifiers held and those change as the user
-- types. A cached set would show the unshifted legends while shift is latched.
function methods.keys(self: Keyboard): { RenderedKey }
  local modifiers: { string } = self:modifiers()
  local seat: lunette.Seat? = self:legendSeat()

  return layout.keysOf(self.rows, self.style, function(entry: Key): string
    return layout.legendFor(entry, seat, modifiers)
  end)
end

-- What is drawn on a key.
--
-- The label takes precedence, because a key that types a control character has
-- nothing else to show. Otherwise the seat's own keymap provides the legend,
-- under the modifiers held. A keysym with no text falls back to its number,
-- not to a blank: a key with nothing on it looks broken, and the number
-- identifies the key.
-- The seat the legends are read from.
--
-- A legend is what a key would type, which only a seat's layout defines. The
-- target is the seat that `mullion.interaction` last focused, and nothing has
-- been focused when a keyboard first appears, so the legends would be blank
-- until the user types somewhere else first. Any seat can provide the
-- legends, so an unfocused keyboard uses the first seat, and no unlabelled
-- grid appears.
function methods.legendSeat(self: Keyboard): lunette.Seat?
  local seat: lunette.Seat?, _ = self.target()
  if seat then
    return seat
  end

  local seats = lunette.seats()
  return seats and seats[1] or nil
end

function methods.legendFor(self: Keyboard, entry: Key, seat: lunette.Seat?, modifiers: { string }): string
  return layout.legendFor(entry, seat, modifiers)
end

-- Where a ray meets this keyboard, in its own metres, and how far away that is.
--
-- The surface contract `mullion.interaction` defines. A panel reports
-- the hit in its source's pixels, which a sink takes; a keyboard has no
-- source, so it reports in the frame its key geometry is already in.
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
-- The key unit is what every row width is a multiple of, so scaling it scales
-- the geometry, the hit test, and the drawing together. The method is part
-- of the surface contract, so a two-handed grab sizes a keyboard the way it
-- sizes a panel.
function methods.setSize(self: Keyboard, width: number?, _height: number?)
  if not width or width <= 0 or self.width <= 0 then
    return
  end

  local scale = width / self.width
  -- Copied key by key, not field by field: naming all eleven would drop a
  -- field added to `Style` later, and nothing would flag the loss. A record
  -- carries no indexer for `pairs` to walk, so the read passes through one,
  -- and the result is a `Style` because it contains every key the original
  -- holds.
  local fields: { [string]: any } = self.style :: any
  local copied: any = {}
  for key, value in pairs(fields) do
    copied[key] = value
  end
  local style: Style = copied

  style.keyUnit = self.style.keyUnit * scale
  style.gap = self.style.gap * scale
  style.margin = self.style.margin * scale
  style.plateDepth = self.style.plateDepth * scale
  style.legendDepth = self.style.legendDepth * scale
  style.legendHeight = self.style.legendHeight * scale

  self.style = style
  self.width, self.height = layout.extentOf(self.rows, style)
end

-- The key a ray meets and how far away it is, or nothing.
--
-- The intersection is `panel.rayQuadHit`, the only raycaster the standard
-- library has. It reports the hit in the source's pixels, so a keyboard
-- passes it its own size in metres as the pixel size: the "pixels" are then
-- metres from the top-left corner, which is the frame the key geometry is
-- already in.
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

-- Presses and releases one key. Reports whether anything was sent.
--
-- A modifier key latches instead and sends nothing: the modifiers go with
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
-- Every character the layout binds goes down the ordinary path, so nothing
-- about the client's keymap changes. A run of characters it does not bind goes
-- to `sink:typeText` in one call, which docs/dev/lua-api.md describes as generating
-- a temporary keymap, uploading it, typing against it, and putting the
-- client's own back. A call per character would swap the keymap once per
-- character.
--
-- The two paths are not interleaved within one character. Each call is
-- queued in order, and each `typeText` restores the keymap before the next
-- command is acted on, so a sequence alternating between them is well
-- defined. docs/dev/lua-api.md warns against a key held down across one, which
-- this never does.
function methods.typeText(self: Keyboard, text: string)
  local seat, sink = self.target()
  if not sink then
    return false
  end
  local typedSink: lunette.Sink = sink
  -- With no seat there is no keymap to use, so every character is text the
  -- layout can show but not express.
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

  -- The last stroke's modifiers remain held. The next stroke loads its own
  -- modifiers before it sends keys.
  typedSink:modifiers(self:modifiers(), seat)
  return true
end

-- Draws the backplate, the keys, and the legends.
function methods.draw(self: Keyboard, pass: Pass): ()
  if self.dead or not self.visible then
    return
  end

  local held = self:modifiers()
  drawing.keyboard(pass, self.pose, self:keys(), self.width, self.height, self.style, {
    held = function(key: RenderedKey): boolean
      return key.modifier ~= nil and self:isHeld(held, key.modifier)
    end,
    hovered = function(key: RenderedKey): boolean
      return self:isHovered(key.code)
    end,
  })
end

-- Withdraws the keyboard and removes it from the list.
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

-- Drops the latched modifiers after a key, and informs the client.
--
-- Nothing is sent when none are latched: a key pressed with no modifier
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

-- Removes a keyboard from the list, so a long session does not accumulate
-- dead entries.
function remove(destroyed: Keyboard)
  for index = 1, #keyboards do
    if keyboards[index] == destroyed then
      table.remove(keyboards, index)
      return
    end
  end
end

-- Registered by name, so a module body running a second time, as a soft
-- reload does, leaves a single hook.
teardown.register('mullion.keyboard', keyboard.teardown)

return keyboard
