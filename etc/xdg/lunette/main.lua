-- The default lunette session.
--
-- lunette loads this session when the user has no configuration of their own.
-- It is also the worked example every new user reads, so it stays small:
-- docs/dev/stdlib.md's tier 4 requires a terminal on a panel, a laser, and a
-- reload key, and a large default configuration would raise the expected size
-- of a configuration.
--
-- It carries two things beyond that requirement: a rules table matched on
-- `appId`, and a saved arrangement restored at startup. Neither is more than a
-- handful of lines, and without them nothing demonstrates that either
-- mechanism exists.
--
-- Everything here is policy. `lunette` is the mechanism underneath; `mullion`
-- is policy written in Lua on top of it. `lunette --dump-config` copies the
-- configuration to $XDG_CONFIG_HOME/lunette, where the user can change it. A
-- configuration that never mentions `mullion` is supported as well; nothing in
-- the loading path assumes the default does.
--
-- Anything the configuration does not draw stays transparent: conf.lua
-- requests the overlay extension, and lunette composites over whatever holds
-- the primary session.

local lunette = require '@lunette'

local adopt = require '@mullion/adopt'
local arc = require '@mullion/layout/arc'
local errors = require '@mullion/error'
local errorPanel = require '@mullion/error/panel'
local interaction = require '@mullion/interaction'
local keyboardModule = require '@mullion/keyboard'
local keycodes = require '@mullion/keycodes'
local laser = require '@mullion/laser'
local panel = require '@mullion/panel'
local raycast = require '@mullion/panel/raycast'
local persist = require '@mullion/persist'
local rules = require '@mullion/rules'
local signal = require '@mullion/signal'
local tag = require '@mullion/tag'

-- The one tag this session shows. Tags are a set. A configuration that uses
-- workspaces declares several and switches between them with `tag.only`.
local WORKSPACE = 'main'

-- The key that reloads the configuration, on the desktop window.
local RELOAD_KEY = 'f5'

-- Keys the desktop reports by name because they produce no text. Everything
-- that produces text arrives through `lovr.textinput`, where the character is
-- already resolved against the desktop's own layout.
local NAMED_KEYS = {
  backspace = keycodes.BACKSPACE,
  ['return'] = keycodes.ENTER,
  kpenter = keycodes.ENTER,
  escape = 1,
  tab = 15,
  up = 103,
  down = 108,
  left = 105,
  right = 106,
  home = 102,
  ['end'] = 107,
  pageup = 104,
  pagedown = 109,
  delete = 111,
  insert = 110,
}

-- Modifiers a chord may carry, as the desktop names them against the names
-- `sink:modifiers` takes.
local MODIFIER_KEYS: { { names: { KeyCode }, modifier: string } } = {
  { names = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { names = { 'lalt', 'ralt' }, modifier = 'alt' },
  { names = { 'lgui', 'rgui' }, modifier = 'logo' },
}

-- The button on the left wrist that shows and hides the keyboard, after
-- WayVR's watch. It attaches to the left hand, so it is always reachable and
-- never occupies the room.
local WRIST = {
  -- Which hand carries it, and which one presses it. The pointing device is
  -- the aim pose, not the grip: the grip points along the handle, and a ray
  -- cast down it misses everything the user is aiming at.
  hand = 'hand/left',
  -- Its position relative to the wearing hand, and its size. Taken from
  -- WayVR's watch (`overlays/watch.rs`). The grip pose has +Z running back
  -- along the handle, so 12.5cm of it is the wrist, not the fist.
  offsetX = -0.03,
  offsetY = -0.01,
  offsetZ = 0.125,
  size = 0.115,
  -- A half turn about the axis WayVR uses. It stands the face up off the
  -- wrist the way a watch rests on it, not lying in line with the arm.
  turn = math.pi,
  axisX = -0.7071066,
  axisY = 0.0007963618,
  axisZ = 0.7071066,
  -- Where the keyboard appears when the button is pressed, relative to the
  -- head: ahead, and below the line of sight so it does not cover the panel
  -- being typed into.
  keyboardDistance = 0.55,
  keyboardDrop = 0.35,
}

-- The keyboard the wrist button shows, created on first use. A session that
-- never uses it never builds it.
local virtualKeyboard: keyboardModule.Keyboard

-- Where the "no windows yet" note is drawn, in metres, and how tall it is.
local NOTE_X, NOTE_Y, NOTE_Z = 0, 1.5, -1.5
local NOTE_HEIGHT = 0.08

-- A demonstration, not policy. lunette itself spawns nothing; the
-- configuration decides what a session opens. The list exists so a fresh
-- installation shows something without a client attached by hand, and so the
-- spawn path is exercised on every run.
--
-- A session that adopts clients started from elsewhere deletes this list and
-- the two functions below it:
--
--   WAYLAND_DISPLAY=wayland-20 foot
--
-- lunette logs the display name it bound as it starts.
local DEMONSTRATION_TERMINALS = { 'ghostty', 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' }

-- The tag every panel joins, and the panels no source gave a pose for.
--
-- A window restored from the saved arrangement, or placed by a rule that
-- specifies a pose, keeps that pose; the arc arranges what is left around it.
-- Rebuilt in `lovr.load`, so a soft reload starts from the new state's tags
-- and panels, not the old state's.
local workspace: tag.Tag? = nil
local unplaced = {}

-- Whether this session has already tried to open its demonstration terminal.
--
-- A global. A soft reload discards the configuration's locals along with
-- everything else the session loaded, and keeps globals
-- (docs/dev/lua-api.md#reload): a local here would be nil again on every reload,
-- and the session would open another terminal each time the user presses F5.
-- Checking whether any panels exist does not work: a user who closed every
-- window and then reloaded would get a fresh one. Written through `_G` so the
-- assignment is visible to the checker.
_G.lunetteDemonstrationSpawned = _G.lunetteDemonstrationSpawned or false

-- Which terminal candidate is being tried, and the handle that attempt
-- produced. A spawn that never started arrives through lunette.onProcessExited
-- with an outcome of 'spawnFailed'; a missing program produces that report, so
-- the fallback proceeds from it, not from anything checkable up front.
local attempt = 0
local attempted = nil

local function spawnNextTerminal()
  attempt = attempt + 1
  local program = DEMONSTRATION_TERMINALS[attempt]
  if not program then
    attempted = nil
    print 'lunette: no terminal emulator was found; start a client yourself with WAYLAND_DISPLAY'
    return
  end

  attempted = lunette.spawn { argv = { program } }
end

-- Writes the arrangement to the save directory. Called when a panel is dropped
-- and when the session quits, the two moments the arrangement changes.
local function saveArrangement()
  local written, message = persist.save(persist.capture(panel.all()))
  if not written then
    print('lunette: the arrangement was not saved: ' .. tostring(message))
  end
end

-- Makes the panel for a window and files it under whichever source placed it.
--
-- Shared by the window-opened subscription and the adoption below: a window
-- already open when the configuration loads and one that opens a moment later
-- are placed the same way. A reload makes both paths occur in one session.
local function place(window)
  local created, properties = rules.place(window, { tags = { WORKSPACE } })

  -- Arrangements and hand placements are written to disk as they happen, so a
  -- session killed without a quit still comes back to its arrangement.
  signal.connect(created, 'dropped', saveArrangement)

  if properties.pose == nil then
    unplaced[#unplaced + 1] = created
  end
  return created
end

-- Puts the panels the arc is responsible for back on the arc, dropping the ones
-- whose windows have gone.
local function arrange()
  local live = {}
  for _, existing in ipairs(unplaced) do
    if not existing.dead then
      live[#live + 1] = existing
    end
  end
  unplaced = live
  arc(unplaced)
end

function lovr.load()
  -- Rate-limits errors and reports them, and is replaceable: it is mullion
  -- code, not native, so a configuration that needs different reporting
  -- writes its own `lovr.errhand` and does not call this.
  errors.install()

  -- The panel the reports are shown on. Separate from the handler because
  -- drawing needs a Pass and reporting does not, and it is drawn from
  -- `lovr.draw` below: a session that reported an error to the log alone
  -- would make the user take the headset off to find out why nothing moved.
  errorPanel.install()

  -- Found before it is made, so `lovr.load` running a second time, a soft
  -- reload, does not raise on a name it declared itself.
  workspace = tag.find(WORKSPACE) or tag.new(WORKSPACE, { selected = true })
  unplaced = {}

  -- One rule, as the worked example. The match is on `appId`, and the property
  -- is a function so it is evaluated when a window opens, not when the
  -- configuration loads: the rule computes "wherever the user is now", not the
  -- position at load time.
  rules.setRules {
    {
      match = { appId = 'firefox' },
      properties = {
        width = 2,
        pose = function()
          return lovr.math.newMat4():translate(-1.4, 1.5, -1.2):rotate(0.9, 0, 1, 0)
        end,
      },
    },
  }

  -- The saved arrangement is a second source, not another rule: after a
  -- restart, a window placed by hand returns to its saved position, and a
  -- window opening fresh is placed by rule. `persist.PRECEDENCE` is above the
  -- rules table, so the saved pose wins; passing a lower number gives the
  -- rules table precedence.
  persist.install(persist.load())

  -- The third source, above both, and the reason a reload does not scramble a
  -- hand-arranged workspace: a panel the user dragged wrote its pose to the
  -- native property store, which persists beyond the Lua state; adopt reads
  -- it back.
  adopt.install()

  -- One laser per hand, each with its own seat, so two hands work independently.
  laser.attach()

  -- After the sources are installed. After a reload, adopt.windows() is the
  -- sole route by which windows still open reach the configuration: the
  -- window-opened subscription from the previous load belongs to the
  -- discarded state. On the first run of a session there is nothing to adopt,
  -- and the call does nothing.
  local adopted = adopt.windows()
  for _, window in ipairs(adopted) do
    place(window)
  end
  arrange()

  -- A restart closes the Lua state, so the global below is gone even though
  -- the windows from the previous session are not
  -- (docs/dev/architecture.md#survival-across-lifecycle-events). Anything to adopt
  -- is a terminal this configuration already opened, so the guard is restored
  -- from what survived, not from what is remembered.
  if #adopted > 0 then
    _G.lunetteDemonstrationSpawned = true
  end

  -- Once per session, and not once per `lovr.load`. A reload runs this callback
  -- again, and one that opened another terminal each time would fill the room by
  -- the third edit.
  if not _G.lunetteDemonstrationSpawned then
    _G.lunetteDemonstrationSpawned = true
    spawnNextTerminal()
  end
end

lunette.onWindowOpened(function(event)
  place(event.window)
  arrange()
end)

lunette.onWindowClosed(function()
  -- The panel over a window that has gone destroys itself on the next update;
  -- arrange() then closes the gap it left in the arc.
  arrange()
end)

lunette.onProcessExited(function(event)
  if not attempted or event.process.id ~= attempted.id then
    return
  end

  if event.outcome == 'spawnFailed' then
    -- A machine without this particular terminal produces this outcome.
    spawnNextTerminal()
  else
    attempted = nil
  end
end)

-- The modifiers held on the desktop keyboard right now, as `sink:modifiers`
-- names them. Shift is absent by design: a shifted character arrives through
-- `lovr.textinput` already shifted, and `seat:strokeFor` returns the modifiers
-- that character needs.
local function heldModifiers()
  local held = {}
  for _, entry in ipairs(MODIFIER_KEYS) do
    for _, name in ipairs(entry.names) do
      if lovr.system.isKeyDown(name) then
        held[#held + 1] = entry.modifier
        break
      end
    end
  end
  return held
end

-- Presses and releases one keycode on whatever holds focus, with `modifiers`
-- held for the duration and cleared afterwards.
local function stroke(keycode: number, modifiers: { string }): boolean
  local seat, sink = interaction.focused()
  if not seat or not sink then
    return false
  end

  if #modifiers > 0 then
    sink:modifiers(modifiers, seat)
  end
  sink:key(keycode, true, seat)
  sink:key(keycode, false, seat)
  if #modifiers > 0 then
    sink:modifiers({}, seat)
  end
  return true
end

-- Text typed on the desktop keyboard reaches the focused panel.
--
-- The character is resolved by the desktop, and `seat:strokeFor` turns it back
-- into the keycode and modifiers this seat's own layout needs for it. The
-- session then types the pressed character, not the character that occupies
-- that position in the seat's layout.
--
-- A character the seat's layout cannot express is dropped. `sink:typeText`
-- would send it, but `sink:typeText` cannot be interleaved with `sink:key` on
-- the same seat, so the stroke path is used throughout.
function lovr.textinput(text: string, _code: number)
  local seat, sink = interaction.focused()
  if not seat or not sink then
    return
  end

  -- A chord is a key event: the letter produces no text while a modifier is
  -- held, so the keycode comes from the letter itself and the modifiers from
  -- the desktop. `lovr.keypressed` handles it.
  local held = heldModifiers()
  if #held > 0 then
    return
  end

  for character in text:gmatch '.' do
    local found = seat:strokeFor(character)
    if found then
      stroke(found.keycode, found.modifiers or {})
    end
  end
end

-- Puts the keyboard where it can be typed on: ahead of the head and below the
-- line of sight, upright, facing the user.
local function placeKeyboard(target: keyboardModule.Keyboard)
  local hx, hy, hz = lovr.headset.getPosition 'head'
  local forwardX, _, forwardZ = lovr.headset.getDirection 'head'

  local flat = vector.pack(forwardX, 0, forwardZ)
  if flat:length() < 0.001 then
    flat = vector.pack(0, 0, -1)
  end
  flat:normalize()

  local setPose = target.setPose
  if not setPose then
    return
  end
  setPose(
    target,
    lovr
      .math
      .newMat4()
      :translate(hx + flat.x * WRIST.keyboardDistance, hy - WRIST.keyboardDrop, hz + flat.z * WRIST.keyboardDistance)
      :rotate(math.atan2(-flat.x, -flat.z), 0, 1, 0)
      -- Tilted back, so it faces a head looking down at it, not straight
      -- ahead past it.
      :rotate(
        -math.pi / 6,
        1,
        0,
        0
      )
  )
end

-- Shows the keyboard when it is down, or hides it when it is up.
--
-- Placement happens on show. A keyboard the user has moved stays where they
-- put it, and reappears there.
local function toggleKeyboard()
  if not virtualKeyboard or virtualKeyboard.dead then
    virtualKeyboard = keyboardModule.new {}
    virtualKeyboard:setVisible(false)
  end

  local showing = not virtualKeyboard.visible
  virtualKeyboard:setVisible(showing)
  if showing then
    placeKeyboard(virtualKeyboard)
  end
end

-- The button on the left wrist, as a surface.
--
-- It attaches to a hand, so its pose is recomputed every frame and not
-- stored. Everything else about it is the surface contract
-- `mullion.interaction` picks against: a raycast, what a press does, and
-- that it is not grabbable.
type WristButton = {
  width: number,
  height: number,
  pose: Mat4?,
  grabbable: boolean,
  tracked: boolean,
  dead: boolean,
  follow: (WristButton) -> boolean,
  -- `any` where `mullion`'s own surfaces name the contract's receiver: the
  -- methods below are assigned straight onto this table, so the annotation has
  -- to be the type whose fields their bodies read.
  raycast: (any, vector, vector, boolean?) -> (number?, number?, number?),
  onPress: (any, number?, number?, unknown?) -> (),
}

local wristButton = (
  {
    width = WRIST.size,
    height = WRIST.size,
    -- Built on first use, and nothing up front. A configuration loads before
    -- the modules it will draw with exist, so a table built at load time
    -- cannot call `lovr.math` any more than it can `lovr.graphics`.
    pose = nil,
    -- A button draggable off the wrist would force the user to put it back.
    -- WayVR's watch is not draggable either.
    grabbable = false,
    tracked = false,
    dead = false,
  }
) :: WristButton

-- Moves the button to where the wrist is, and reports whether the wrist is
-- tracked.
function wristButton.follow(self: WristButton)
  self.tracked = lovr.headset.isTracked(WRIST.hand)
  if not self.tracked then
    return false
  end

  local pose = self.pose or lovr.math.newMat4()
  local mx, my, mz, qx, qy, qz, qw = lovr.headset.getPose(WRIST.hand)
  local tmp = lovr.math.newMat4(mx, my, mz, qx, qy, qz, qw)
  pose:set(tmp)
  pose:translate(WRIST.offsetX, WRIST.offsetY, WRIST.offsetZ)
  pose:rotate(WRIST.turn, WRIST.axisX, WRIST.axisY, WRIST.axisZ)
  self.pose = pose
  return true
end

function wristButton.raycast(self: WristButton, origin: vector, direction: vector)
  if not self.tracked then
    local x: number? = nil
    local y: number? = nil
    local z: number? = nil
    return x, y, z
  end

  local pose = self.pose or lovr.math.newMat4()
  return raycast.hit({
    pose = pose,
    width = self.width,
    height = self.height,
    -- The raycast returns a coordinate this surface has no use for, and
    -- rejects a quad that declares no size.
    pixelWidth = 1,
    pixelHeight = 1,
    -- Hittable from either side. Which way a wrist faces depends on how the arm
    -- is held, and a button pressable from one side would force the user to
    -- work out its orientation first.
    backFace = true,
  }, origin, direction)
end

function wristButton.onPress(self: WristButton, _x: number?, _y: number?, _pointer: unknown?)
  toggleKeyboard()
  lovr.headset.vibrate(WRIST.hand, 0.3, 0.05, 0)
end

-- Draws the wrist button, so there is something to aim at.
local function drawWrist(pass: Pass)
  if not wristButton.tracked then
    return
  end

  local showing = virtualKeyboard and virtualKeyboard.visible and not virtualKeyboard.dead
  if showing then
    pass:setColor(0.35, 0.75, 0.45, 1)
  else
    pass:setColor(0.2, 0.2, 0.24, 1)
  end
  local buttonPose: Mat4? = wristButton.pose
  if not buttonPose then
    return
  end
  pass:plane(lovr.math.mat4(buttonPose):scale(wristButton.width, wristButton.height, 1), 'fill', 1, 1)

  -- In front of the face, not on it. Text at the same depth as the quad
  -- competes with it for the depth buffer and flickers as the hand moves.
  pass:setColor(1, 1, 1, 1)
  local textPose: Mat4? = wristButton.pose
  if not textPose then
    return
  end
  pass:text(
    'kbd',
    lovr.math.mat4(textPose):translate(0, 0, 0.002):scale(vector.pack(wristButton.width * 0.35)),
    0,
    'center',
    'middle'
  )
end

-- Everything a pointer may hit this frame: the tag's panels, the wrist button,
-- and the keyboard when it is up.
--
-- The pointer picks the nearest and routes to it. Nothing here raycasts, so
-- the frame keeps one raycaster and no second one to reconcile.
local function surfaces(): { interaction.Surface }
  local list: { interaction.Surface } = {}
  -- Appended through a function, not written into the list directly: writing
  -- through an index checks against the element type exactly, where a
  -- parameter checks that the argument satisfies the contract.
  local function add(surface: interaction.Surface)
    list[#list + 1] = surface
  end

  -- Walked from the panels, not from the tag's members, because a tag holds
  -- anything with a pose and the list takes what a pointer can hit. The
  -- membership test checks the same condition in reverse.
  if workspace then
    for _, existing in ipairs(panel.all()) do
      if workspace:has(existing) then
        add(existing)
      end
    end
  end
  if wristButton and wristButton.follow(wristButton) then
    add(wristButton)
  end
  if virtualKeyboard and virtualKeyboard.visible and not virtualKeyboard.dead then
    add(virtualKeyboard)
  end
  return list
end

function lovr.keypressed(key: KeyCode, _scancode: number, _isrepeat: boolean)
  if key ~= RELOAD_KEY then
    local named = NAMED_KEYS[key]
    if named then
      stroke(named, heldModifiers())
      return
    end

    local held = heldModifiers()
    if #held > 0 and #key == 1 then
      local seat = interaction.focused()
      local found = seat and seat:strokeFor(key)
      if found then
        stroke(found.keycode, held)
      end
    end
    return
  end

  -- Returns false and the message, and does not raise, so a configuration
  -- with a typo stays running and reports it. The clients are not disturbed
  -- either way: a soft reload is a matter of the Lua state alone.
  local reloaded, message = lunette.reload()
  if not reloaded then
    print('lunette: the configuration was not reloaded: ' .. tostring(message))
  end
end

function lovr.update(_dt: number)
  panel.update()
  laser.update(surfaces())
end

function lovr.draw(pass: Pass): boolean
  panel.draw(pass)
  drawWrist(pass)
  keyboardModule.draw(pass)
  -- After everything it points at, so a beam is drawn over the surface it ends
  -- on, not into it.
  laser.draw(pass)

  if #panel.all() == 0 then
    -- The height is carried in the transform. `Pass:text` reads the argument
    -- after a `Mat4` as the wrap width, so a scale passed there would set the
    -- wrap instead and leave the text at its full size.
    pass:text(
      'lunette: no windows yet',
      lovr.math.mat4():translate(NOTE_X, NOTE_Y, NOTE_Z):scale(NOTE_HEIGHT),
      0,
      'center',
      'middle'
    )
  end

  -- Last, so it is drawn over whatever it is in front of.
  errorPanel.draw(pass)
  -- False, not true: a truthy return counts as the callback having submitted
  -- the pass itself, and the frame is then never presented.
  return false
end

function lovr.quit(): boolean
  saveArrangement()
  -- False, not true: a truthy return vetoes the quit, and the session cannot
  -- then be closed.
  return false
end
