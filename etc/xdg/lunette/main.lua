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

-- The fragment stage for a window whose buffer has no alpha channel.
--
-- An X-variant fourcc such as XR24 has no Vulkan format of its own, so it is
-- imported as the alpha-carrying format with the same component order and the
-- client's padding byte arrives as alpha. Most renderers leave that byte at
-- zero, so sampling it draws the window fully invisible. window.opaque is what
-- says the byte means nothing; this is what acts on it. docs/rendering.md
-- records both.
local OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]]

-- Built in lovr.load, which is the first moment the graphics module exists.
local opaqueShader = nil

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
  opaqueShader = lovr.graphics.newShader('unlit', OPAQUE_FRAGMENT)
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

  -- A client's buffer holds premultiplied alpha: a terminal at opacity 0.8
  -- writes 0.8 into every channel, alpha included. LÖVR's default alpha mode
  -- multiplies the colour by the alpha again in the shader, which darkens a
  -- translucent window twice.
  pass:setBlendMode('alpha', 'premultiplied')

  -- This buffer's fourth component is padding, so the shader replaces it with
  -- one instead of sampling it.
  if window.opaque then
    pass:setShader(opaqueShader)
  end

  pass:setMaterial(texture)
  pass:plane(QUAD_X, QUAD_Y, QUAD_Z, QUAD_HEIGHT * aspect, QUAD_HEIGHT)
  pass:setMaterial()
  pass:setShader()
  pass:setBlendMode('alpha', 'alphamultiply')
end
