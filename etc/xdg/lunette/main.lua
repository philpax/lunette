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

local arc = require 'mullion.layout.arc'
local errors = require 'mullion.error'
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

  -- One laser per hand, each with its own seat, so two hands work independently.
  laser.attach()

  spawnNextTerminal()
end

function lovr.lunwindowopened(event)
  local created, properties = rules.place(event.window, { tags = { WORKSPACE } })

  -- Saved arrangements and hand placements are written to disk as they happen,
  -- so that a session that is killed rather than quit still comes back where it
  -- was.
  signal.connect(created, 'dropped', saveArrangement)

  if properties.pose == nil then
    unplaced[#unplaced + 1] = created
    arrange()
  end
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

function lovr.keypressed(key)
  if key ~= RELOAD_KEY then
    return
  end

  -- `lunette.reload` arrives with the reload mechanism, which is not built yet.
  -- Guarded rather than assumed, so that the key says what it would have done
  -- instead of stopping the session with an error about a nil value.
  if lunette.reload then
    lunette.reload()
  else
    print('lunette: reload is not implemented yet')
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
end

function lovr.quit()
  saveArrangement()
end
