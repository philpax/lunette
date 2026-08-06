-- The default lunette session.
--
-- It draws the first window the compositor is showing on a quad in front of the
-- viewer. That is the whole import path end to end: a client commits a buffer,
-- the compositor imports it, and the texture it becomes is sampled here.
--
-- Anything this does not draw stays transparent, because conf.lua requests the
-- overlay extension, so lunette composites over whatever holds the primary
-- session.

local lunette = require 'lunette'

-- Where the quad sits, in metres, and how tall it is. A fixed pose: placing
-- windows is mullion's job, and mullion is not written yet.
local QUAD_X, QUAD_Y, QUAD_Z = 0, 1.6, -1.5
local QUAD_HEIGHT = 0.8

-- What to fall back to when a window reports no size, which a handle that has
-- not yet seen its window in a snapshot does.
local DEFAULT_ASPECT = 16 / 9

-- A demonstration, not policy. lunette itself spawns nothing; what a session
-- opens is mullion's decision, and mullion is not written yet. This exists so
-- that a fresh installation shows something without a client being attached by
-- hand, and so that the spawn path is exercised on every run.
--
-- Delete this block and the two functions below it for a session that only
-- adopts clients started from elsewhere, which is the other half of the same
-- workflow:
--
--   WAYLAND_DISPLAY=wayland-20 foot
--
-- lunette logs the display name it bound as it starts.
local DEMONSTRATION_TERMINALS = { 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' }

-- Which candidate is being tried, and the handle it was tried with. A spawn
-- that never started arrives as lovr.lunprocessexited with an outcome of
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

function lovr.load()
  spawnNextTerminal()
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

function lovr.draw(pass)
  local window = lunette.windows()[1]
  if not window then
    pass:text('lunette: no windows yet', QUAD_X, QUAD_Y, QUAD_Z, 0.1)
    return
  end

  -- Never cached across frames: the texture rotates as the client cycles its
  -- buffers. It is false while the client is gone or has committed nothing.
  local texture = window:getTexture()
  if not texture then
    pass:text('lunette: ' .. (window.title or 'a window'), QUAD_X, QUAD_Y, QUAD_Z, 0.1)
    return
  end

  local aspect = DEFAULT_ASPECT
  if window.width > 0 and window.height > 0 then
    aspect = window.width / window.height
  end

  pass:setMaterial(texture)
  pass:plane(QUAD_X, QUAD_Y, QUAD_Z, QUAD_HEIGHT * aspect, QUAD_HEIGHT)
  pass:setMaterial()
end
