-- The default lunette session.
--
-- This file contains policy implemented with the `mullion` standard library.
-- The overlay remains transparent outside the configured panels.

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

-- The one tag this session shows. Tags are a set, and a configuration wanting
-- workspaces declares several and switches between them with `tag.only`.
local WORKSPACE = 'main'

-- The key that reloads the configuration, on the desktop window.
local RELOAD_KEY = 'f5'

-- Keys the desktop reports by name because they produce no text. Everything
-- that does produce text arrives through `lovr.textinput` instead, where the
-- character is already resolved against the desktop's own layout.
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

-- The button on the left wrist that shows and hides the keyboard. It stays on
-- the hand so it remains reachable without occupying the room.
local WRIST = {
  -- Use the aim pose for pointing so the ray follows what the user is aiming at.
  hand = 'hand/left',
  -- Position and size relative to the wearing hand.
  offsetX = -0.03,
  offsetY = -0.01,
  offsetZ = 0.125,
  size = 0.115,
  -- Rotate the face up from the wrist instead of aligning it with the arm.
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

-- The keyboard the wrist button shows, created on first use so a session that
-- never asks for one never builds it.
local virtualKeyboard: keyboardModule.Keyboard

-- Where the "no windows yet" note is drawn, in metres, and how tall it is.
local NOTE_X, NOTE_Y, NOTE_Z = 0, 1.5, -1.5
local NOTE_HEIGHT = 0.08

-- A demonstration, not policy. lunette itself spawns nothing; what a session
-- opens is this file's decision. This exists so that a fresh installation shows
-- something without a client being attached by hand, and so that the spawn path
-- is exercised on every run.
--
local DEMONSTRATION_TERMINALS = { 'ghostty', 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' }

-- The tag every panel joins, and the panels no source gave a pose for.
--
-- A window restored from the saved arrangement, or placed by a rule that names a
-- pose, keeps that pose; the arc arranges what is left around it. Rebuilt in
-- `lovr.load`, so a soft reload starts from the tags and panels the new state
-- makes rather than from the old one's.
local workspace: tag.Tag? = nil
local unplaced = {}

-- Whether this session has already tried to open its demonstration terminal.
--
-- This state is global so it survives configuration reloads and prevents another
-- demonstration terminal from being opened.
_G.lunetteDemonstrationSpawned = _G.lunetteDemonstrationSpawned or false

-- Which terminal candidate is being tried, and the handle it was tried with. A
-- spawn that never started arrives through lunette.onProcessExited with an outcome of
-- 'spawnFailed', and that is the only report a missing program produces, so the
-- fallback is driven from there rather than from anything checkable up front.
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
-- and when the session quits, which are the two moments the arrangement has
-- changed and is worth keeping.
local function saveArrangement()
  local written, message = persist.save(persist.capture(panel.all()))
  if not written then
    print('lunette: the arrangement was not saved: ' .. tostring(message))
  end
end

-- Makes the panel for a window and files it under whichever source placed it.
--
-- Shared by the window-opened subscription and adoption so both paths place
-- windows consistently.
local function place(window)
  local created, properties = rules.place(window, { tags = { WORKSPACE } })

  -- Saved arrangements and hand placements are written to disk as they happen,
  -- so that a session that is killed rather than quit still comes back where it
  -- was.
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
  -- Install error handling before the rest of the session starts.
  errors.install()

  -- Install the panel that displays errors in the session.
  errorPanel.install()

  -- Reuse the tag when the session is loaded again.
  workspace = tag.find(WORKSPACE) or tag.new(WORKSPACE, { selected = true })
  unplaced = {}

  -- Place Firefox windows at a fixed size and pose.
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

  -- Restore saved arrangements with higher precedence than the default rules.
  persist.install(persist.load())

  -- Restore properties retained by the native window state.
  adopt.install()

  -- Attach an independent laser and seat for each hand.
  laser.attach()

  -- Adopt windows that were already open when this state started.
  local adopted = adopt.windows()
  for _, window in ipairs(adopted) do
    place(window)
  end
  arrange()

  -- Existing windows indicate that the demonstration terminal was already opened.
  if #adopted > 0 then
    _G.lunetteDemonstrationSpawned = true
  end

  -- Open at most one demonstration terminal for the session.
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
  -- this is what closes the gap it left in the arc.
  arrange()
end)

lunette.onProcessExited(function(event)
  if not attempted or event.process.id ~= attempted.id then
    return
  end

  if event.outcome == 'spawnFailed' then
    -- Expected on a machine without this particular terminal.
    spawnNextTerminal()
  else
    attempted = nil
  end
end)

-- The modifiers held on the desktop keyboard, using the names accepted by the
-- input sink. Shifted characters arrive through `lovr.textinput` already resolved.

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
-- into the keycode and modifiers this seat's own layout needs for it. That is
-- what keeps a session whose seat differs from the desktop's layout typing the
-- character that was pressed rather than the one in that position.
--
-- A character the seat's layout cannot express is dropped. `sink:typeText` is
-- what that case is for, and it may not be interleaved with `sink:key` on the
-- same seat, so it is not reached from here.
function lovr.textinput(text: string, _code: number)
  local seat, sink = interaction.focused()
  if not seat or not sink then
    return
  end

  -- A chord is a key event rather than text, and `lovr.keypressed` has it.
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
      -- Tilted back, so it faces a head looking down at it rather than straight
      -- ahead past it.
      :rotate(
        -math.pi / 6,
        1,
        0,
        0
      )
  )
end

-- Shows the keyboard, or hides it if it is already up.
--
-- Placed only when it is shown. A keyboard the user has moved stays where they
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
-- It rides a hand, so its pose is recomputed every frame rather than stored.
-- Everything else about it is the surface contract `mullion.interaction` picks
-- against: a raycast, what a press does, and a refusal to be picked up.
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
    -- Built on first use, and nothing before it. A configuration is loaded before
    -- the modules it will draw with exist, so a table built at load time cannot
    -- reach for `lovr.math` any more than it can for `lovr.graphics`.
    pose = nil,
    -- Keep the button attached to the wrist.

    grabbable = false,
    tracked = false,
    dead = false,
  }
) :: WristButton

-- Moves the button to where the wrist is, and says whether it is there at all.
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
    -- The raycast answers a coordinate this surface has no use for, and refuses
    -- a quad claiming no size to answer it in.
    pixelWidth = 1,
    pixelHeight = 1,
    -- Hittable from either side. Which way a wrist faces depends on how the arm
    -- is held, and a button pressable from one side only is one whose
    -- orientation the user has to work out first.
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

  -- In front of the face rather than on it. Text at the same depth as the quad
  -- fights it for the depth buffer and flickers as the hand moves.
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
-- The pointer picks the nearest and routes to it. Nothing here raycasts, which
-- is what keeps one raycaster rather than several that have to agree.
local function surfaces(): { interaction.Surface }
  local list: { interaction.Surface } = {}
  -- Appended through a function rather than written into the list directly:
  -- writing through an index checks against the element type exactly, where a
  -- parameter checks that the argument satisfies the contract, which is the
  -- question being asked.
  local function add(surface: interaction.Surface)
    list[#list + 1] = surface
  end

  -- Walked from the panels rather than from the tag's members, because a tag
  -- holds anything with a pose and this needs what a pointer can hit. The
  -- membership test is the same question asked the other way round.
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

    -- A chord: the letter produces no text while a modifier is held, so the
    -- keycode comes from the letter itself and the modifiers from the desktop.
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

  -- Report reload errors without interrupting the running session.
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
  -- on rather than into it.
  laser.draw(pass)

  if #panel.all() == 0 then
    -- The height rides in the transform. `Pass:text` reads the argument after a
    -- `Mat4` as the wrap width, so a scale passed there would set the wrap
    -- instead and leave the text at its full size.
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
  -- Return false so the frame is presented normally.
  return false
end

function lovr.quit(): boolean
  saveArrangement()
  -- Return false so quitting proceeds.
  return false
end
