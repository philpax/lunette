-- The default lunette session.
--
-- lunette loads this when the user has none of their own. It is also the worked
-- example every new user reads, so it stays small: docs/stdlib.md's tier 4 asks
-- for a terminal on a panel, a laser, and a reload key, and a large default
-- configuration would teach that a large one is necessary.
--
-- It carries two things past that line, both because the phase's acceptance
-- criteria are about them: a rules table matched on `appId`, and a saved
-- arrangement that is restored at startup. Neither is more than a handful of
-- lines, and without them nothing demonstrates that either mechanism exists.
--
-- Everything here is policy. `lunette` is the mechanism underneath, `mullion` is
-- policy written in Lua on top of it, and this file is one arrangement of that
-- policy — copy it to $XDG_CONFIG_HOME/lunette and change whatever you like. A
-- configuration that never mentions `mullion` is supported too; nothing in the
-- loading path assumes this one does.
--
-- Anything this does not draw stays transparent, because conf.lua requests the
-- overlay extension, so lunette composites over whatever holds the primary
-- session.

local lunette = require 'lunette'

local adopt = require 'mullion.adopt'
local arc = require 'mullion.layout.arc'
local errors = require 'mullion.error'
local errorPanel = require 'mullion.error.panel'
local interaction = require 'mullion.interaction'
local keycodes = require 'mullion.keycodes'
local laser = require 'mullion.laser'
local panel = require 'mullion.panel'
local persist = require 'mullion.persist'
local rules = require 'mullion.rules'
local signal = require 'mullion.signal'
local tag = require 'mullion.tag'

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
local MODIFIER_KEYS = {
  { names = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { names = { 'lalt', 'ralt' }, modifier = 'alt' },
  { names = { 'lgui', 'rgui' }, modifier = 'logo' },
}

-- Where the "no windows yet" note is drawn, in metres, and how tall it is.
local NOTE_X, NOTE_Y, NOTE_Z = 0, 1.5, -1.5
local NOTE_HEIGHT = 0.08

-- A demonstration, not policy. lunette itself spawns nothing; what a session
-- opens is this file's decision. This exists so that a fresh installation shows
-- something without a client being attached by hand, and so that the spawn path
-- is exercised on every run.
--
-- Delete this list and the two functions below it for a session that only adopts
-- clients started from elsewhere, which is the other half of the same workflow:
--
--   WAYLAND_DISPLAY=wayland-20 foot
--
-- lunette logs the display name it bound as it starts.
local DEMONSTRATION_TERMINALS = { 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' }

-- The tag every panel joins, and the panels no source gave a pose for.
--
-- A window restored from the saved arrangement, or placed by a rule that names a
-- pose, keeps that pose; the arc arranges what is left around it. Rebuilt in
-- `lovr.load`, so a soft reload starts from the tags and panels the new state
-- makes rather than from the old one's.
local workspace = nil
local unplaced = {}

-- Whether this session has already tried to open its demonstration terminal.
--
-- A global, deliberately. A soft reload discards this file's locals along with
-- everything else it loaded, and keeps globals
-- (docs/lua-api.md#reload) — so a local here would be nil again on every reload
-- and the session would open another terminal each time the user pressed F5.
-- Asking whether any panels exist instead answers the wrong question: a user who
-- closed every window and then reloaded would get a fresh one.
lunetteDemonstrationSpawned = lunetteDemonstrationSpawned or false

-- Which terminal candidate is being tried, and the handle it was tried with. A
-- spawn that never started arrives as lovr.lunprocessexited with an outcome of
-- 'spawnFailed', and that is the only report a missing program produces, so the
-- fallback is driven from there rather than from anything checkable up front.
local attempt = 0
local attempted = nil

local function spawnNextTerminal()
  attempt = attempt + 1
  local program = DEMONSTRATION_TERMINALS[attempt]
  if not program then
    attempted = nil
    print('lunette: no terminal emulator was found; start a client yourself with WAYLAND_DISPLAY')
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
-- Shared by `lovr.lunwindowopened` and the adoption below, because a window that
-- was already open when this file ran and one that opens a moment later should
-- end up in the same place. A reload is what makes the two happen in one
-- session.
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
  -- Rate-limits errors and reports them, and is replaceable: it is mullion code
  -- rather than native, so a configuration wanting different reporting writes
  -- its own `lovr.errhand` instead of calling this.
  errors.install()

  -- The panel the reports are shown on. Separate from the handler because
  -- drawing needs a Pass and reporting does not, and it is drawn from
  -- `lovr.draw` below: a session that reported an error only to the log would
  -- be one where the user has to take the headset off to find out why nothing
  -- moved.
  errorPanel.install()

  -- Found before it is made, so that `lovr.load` running a second time — which
  -- is what a soft reload does — does not raise on a name it declared itself.
  workspace = tag.find(WORKSPACE) or tag.new(WORKSPACE, { selected = true })
  unplaced = {}

  -- One rule, as the worked example. The match is on `appId`, and the property
  -- is a function so that it is evaluated when a window opens rather than when
  -- this file loads — which is what lets a rule say "wherever the user is now"
  -- rather than baking in wherever they were at startup.
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

  -- The saved arrangement is a second source rather than another rule: after a
  -- restart a window that was hand-placed should come back where it was, and a
  -- window opening fresh should be placed by rule. `persist.PRECEDENCE` is above
  -- the rules table, so the saved pose wins; passing a lower number is how a
  -- configuration says the rules should.
  persist.install(persist.load())

  -- The third source, above both, and the reason a reload does not scramble a
  -- hand-arranged workspace: a panel the user dragged wrote its pose to the
  -- native property store, which outlives the Lua state, and this is what reads
  -- it back.
  adopt.install()

  -- One laser per hand, each with its own seat, so two hands work independently.
  laser.attach()

  -- After the sources are installed, and after a reload the only way this file
  -- hears about the windows that are still open: `lovr.lunwindowopened` was
  -- delivered to the state that has gone. On the first run of a session there is
  -- nothing to adopt yet, and this does nothing.
  for _, window in ipairs(adopt.windows()) do
    place(window)
  end
  arrange()

  -- Once per session, and not once per `lovr.load`. A reload runs this callback
  -- again, and one that opened another terminal each time would fill the room by
  -- the third edit.
  if not lunetteDemonstrationSpawned then
    lunetteDemonstrationSpawned = true
    spawnNextTerminal()
  end
end

function lovr.lunwindowopened(event)
  place(event.window)
  arrange()
end

function lovr.lunwindowclosed()
  -- The panel over a window that has gone destroys itself on the next update;
  -- this is what closes the gap it left in the arc.
  arrange()
end

function lovr.lunprocessexited(event)
  if not attempted or event.process.id ~= attempted.id then
    return
  end

  if event.outcome == 'spawnFailed' then
    -- Expected on a machine without this particular terminal.
    spawnNextTerminal()
  else
    attempted = nil
  end
end

-- The modifiers held on the desktop keyboard right now, as `sink:modifiers`
-- names them. Shift is deliberately absent: a shifted character arrives through
-- `lovr.textinput` already shifted, and `seat:strokeFor` says which modifiers
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
local function stroke(keycode, modifiers)
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
function lovr.textinput(text)
  local seat, sink = interaction.focused()
  if not seat or not sink then
    return
  end

  -- A chord is a key event rather than text, and `lovr.keypressed` has it.
  local held = heldModifiers()
  if #held > 0 then
    return
  end

  for character in text:gmatch('.') do
    local found = seat:strokeFor(character)
    if found then
      stroke(found.keycode, found.modifiers or {})
    end
  end
end

function lovr.keypressed(key)
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

  -- Answers false and the message rather than raising, so a configuration with
  -- a typo in it leaves the session running and says so. The clients are not
  -- disturbed either way: a soft reload is a matter of the Lua state alone.
  local reloaded, message = lunette.reload()
  if not reloaded then
    print('lunette: the configuration was not reloaded: ' .. tostring(message))
  end
end

function lovr.update()
  panel.update()
  laser.update(workspace and workspace:panels() or {})
end

function lovr.draw(pass)
  panel.draw(pass)
  laser.draw(pass)

  if #panel.all() == 0 then
    pass:text('lunette: no windows yet', NOTE_X, NOTE_Y, NOTE_Z, NOTE_HEIGHT)
  end

  -- Last, so it is drawn over whatever it is in front of.
  errorPanel.draw(pass)
end

function lovr.quit()
  saveArrangement()
end
