-- Safe mode: the configuration lunette runs when the user's will not load.
--
-- This file is compiled into the binary rather than installed, and
-- crates/lunette/src/safe_mode.rs is what embeds it. That is the whole point of
-- it: safe mode exists for the moment `main.lua` fails to load, and a broken
-- standard library, a missing install, or a bad LUNETTE_STDLIB_PATH is one of
-- the reasons it might have. So this requires `lunette` and nothing else — no
-- `mullion`, no file on disk, nothing that a broken installation could take
-- away.
--
-- It deliberately resembles etc/xdg/lunette/main.lua and shares no code with
-- it. The duplication is the price of always working, and neither site should be
-- simplified by pointing at the other.
--
-- Enough to see something, spawn a terminal, point at it, and reload — rather
-- than taking the headset off to edit a file. Everything past that is the
-- user's configuration's business, and this is not it.

local lunette = require 'lunette'

-- Where the panel sits, in metres, and how tall it is. Fixed and axis-aligned:
-- a pose the user could move is a panel with a grab, and a grab is a feature
-- safe mode does not have. Being axis-aligned is also why the intersection below
-- is four lines rather than a matrix inversion.
local PANEL_X, PANEL_Y, PANEL_Z = 0, 1.5, -1.5
local PANEL_HEIGHT = 0.9

-- What to fall back to when the window reports no size, which a handle that has
-- not yet seen its window in a snapshot does.
local DEFAULT_ASPECT = 16 / 9

-- Where the notes are drawn, and how tall, when there is no window to show.
local NOTE_HEIGHT = 0.07

-- How far a beam is drawn when it meets nothing, in metres.
local BEAM_LENGTH = 1.5

-- The key that reloads the user's configuration, on the desktop window.
local RELOAD_KEY = 'f5'

-- The hands, as the pointer-ray device each is aimed with and the controller
-- each is clicked with. The pointer ray is where the runtime says the user is
-- aiming, which is not where the controller is pointing.
local HANDS = {
  { pointer = 'hand/left/point', controller = 'hand/left' },
  { pointer = 'hand/right/point', controller = 'hand/right' },
}

-- The candidates tried, in order, until one starts. A spawn that never started
-- arrives as `lovr.lunprocessexited` with an outcome of 'spawnFailed', and that
-- is the only report a missing program produces.
local TERMINALS = { 'foot', 'weston-terminal', 'alacritty', 'kitty', 'xterm' }

-- The fragment stage for a buffer whose fourth component is padding rather than
-- alpha. Sampling it draws the window fully invisible, and `window.opaque` is
-- what says so.
local OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]]

-- Built in `lovr.load`, which is the first moment the graphics module exists,
-- and left as nothing when there is no graphics module to build it from.
local opaqueShader = nil

-- Which terminal is being tried, and the handle it was tried with.
local attempt = 0
local attempted = nil

-- Whether each hand's trigger was down last frame, and what it was pressed on.
-- A release goes to whatever took the press, even when the ray has left it: a
-- release delivered somewhere else would leave the first client holding a button
-- down for the rest of the session.
local pressed = {}
local pressedSink = {}

-- The first window lunette is showing, or nothing.
local function firstWindow()
  local window = lunette.windows()[1]
  if not window or window.dead then
    return nil
  end
  return window
end

-- The panel's size in metres, from the window's aspect.
local function panelSize(window)
  local aspect = DEFAULT_ASPECT
  if window and window.width > 0 and window.height > 0 then
    aspect = window.width / window.height
  end
  return PANEL_HEIGHT * aspect, PANEL_HEIGHT
end

-- Where a ray meets the panel, in the window's own pixels, or nothing.
--
-- The panel faces +z and does not rotate, so the plane is z = PANEL_Z and the
-- solve is a division. The vertical axis flips on the way out: the panel's +y is
-- up and a surface's +y is down.
local function hit(window, originX, originY, originZ, directionX, directionY, directionZ)
  if directionZ == 0 then
    return nil
  end

  local distance = (PANEL_Z - originZ) / directionZ
  if not (distance > 0) then
    return nil
  end

  local width, height = panelSize(window)
  local x = originX + distance * directionX - PANEL_X
  local y = originY + distance * directionY - PANEL_Y
  if x < -width / 2 or x > width / 2 or y < -height / 2 or y > height / 2 then
    return nil
  end

  local pixelWidth = (window.width > 0) and window.width or 0
  local pixelHeight = (window.height > 0) and window.height or 0
  if pixelWidth == 0 or pixelHeight == 0 then
    return nil
  end

  return (x + width / 2) / width * pixelWidth,
    (height / 2 - y) / height * pixelHeight,
    distance
end

local function spawnNextTerminal()
  attempt = attempt + 1
  local program = TERMINALS[attempt]
  if not program then
    attempted = nil
    print('lunette: safe mode found no terminal emulator to spawn')
    return
  end

  attempted = lunette.spawn { argv = { program } }
end

-- One hand's frame: where it points, what it hit, and what its trigger did.
local function updateHand(index, hand, window)
  local headset = lovr.headset
  if not headset.isTracked(hand.pointer) then
    -- A hand that stopped being tracked releases what it was holding. Leaving
    -- the button down would hand a client a press nothing ever releases.
    if pressed[index] and pressedSink[index] then
      pressedSink[index]:button('left', false)
    end
    pressed[index], pressedSink[index] = false, nil
    return nil
  end

  local originX, originY, originZ = headset.getPosition(hand.pointer)
  local directionX, directionY, directionZ = headset.getDirection(hand.pointer)
  local x, y, distance
  if window then
    x, y, distance = hit(window, originX, originY, originZ, directionX, directionY, directionZ)
  end

  local sink = window and window.sink or nil
  if x and sink then
    sink:pointer(x, y)
  end

  local down = headset.isDown(hand.controller, 'trigger') and true or false
  if down ~= pressed[index] then
    pressed[index] = down
    if down then
      if x and sink then
        pressedSink[index] = sink
        sink:button('left', true)
      end
    elseif pressedSink[index] then
      pressedSink[index]:button('left', false)
      pressedSink[index] = nil
    end
  end

  return {
    originX = originX,
    originY = originY,
    originZ = originZ,
    directionX = directionX,
    directionY = directionY,
    directionZ = directionZ,
    distance = distance,
  }
end

-- Where each hand's beam was aimed last frame, so the beam is drawn where the
-- hit test happened rather than where the hand has moved to since.
local beams = {}

function lovr.load()
  if lovr.graphics then
    opaqueShader = lovr.graphics.newShader('unlit', OPAQUE_FRAGMENT)
  end
  spawnNextTerminal()
end

function lovr.lunprocessexited(event)
  if not attempted or event.process.id ~= attempted.id then
    return
  end

  if event.outcome == 'spawnFailed' then
    spawnNextTerminal()
  else
    attempted = nil
  end
end

function lovr.keypressed(key)
  if key ~= RELOAD_KEY then
    return
  end

  -- This is the whole point of safe mode: the user fixes the file at a desk or
  -- through an editor they can reach, presses the key, and the session they were
  -- in comes back without the headset coming off.
  --
  -- A reload that fails answers false and the message rather than raising, so a
  -- second broken configuration leaves safe mode running and says why.
  local reloaded, message = lunette.reload()
  if not reloaded then
    print('lunette: the configuration still does not load: ' .. tostring(message))
  end
end

function lovr.update()
  beams = {}
  if not lovr.headset then
    return
  end

  local window = firstWindow()
  for index, hand in ipairs(HANDS) do
    -- Appended rather than assigned at `index`: an untracked left hand would
    -- otherwise leave a hole that `ipairs` stops at, and the right hand's beam
    -- would never be drawn.
    local aimed = updateHand(index, hand, window)
    if aimed then
      beams[#beams + 1] = aimed
    end
  end
end

function lovr.draw(pass)
  local window = firstWindow()

  pass:text(
    'lunette: safe mode. The configuration did not load; see the log.',
    PANEL_X,
    PANEL_Y + PANEL_HEIGHT / 2 + NOTE_HEIGHT,
    PANEL_Z,
    NOTE_HEIGHT
  )

  -- Never cached across frames: the texture rotates as the client cycles its
  -- buffers, and is false while the client has committed nothing.
  local texture = window and window:getTexture() or nil
  if texture then
    local width, height = panelSize(window)
    -- A client's buffer holds premultiplied alpha; the default alpha mode would
    -- multiply by it a second time and darken a translucent window twice.
    pass:setBlendMode('alpha', 'premultiplied')
    if window.opaque and opaqueShader then
      pass:setShader(opaqueShader)
    end
    pass:setMaterial(texture)
    pass:plane(PANEL_X, PANEL_Y, PANEL_Z, width, height)
    pass:setMaterial()
    if window.opaque and opaqueShader then
      pass:setShader()
    end
    pass:setBlendMode('alpha', 'alphamultiply')
  else
    pass:text('waiting for a terminal', PANEL_X, PANEL_Y, PANEL_Z, NOTE_HEIGHT)
  end

  for _, beam in ipairs(beams) do
    local distance = beam.distance or BEAM_LENGTH
    pass:line(
      beam.originX,
      beam.originY,
      beam.originZ,
      beam.originX + beam.directionX * distance,
      beam.originY + beam.directionY * distance,
      beam.originZ + beam.directionZ * distance
    )
  end
end
