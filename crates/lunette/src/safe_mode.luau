-- Safe mode displays configuration load errors, starts a terminal, and supports reload.
-- Its sole dependency is `@lunette` because the standard library may be unavailable after a load failure.

local lunette = require '@lunette'

type Hand = { read pointer: Device, read controller: Device }
type Beam = {
  read originX: number,
  read originY: number,
  read originZ: number,
  read directionX: number,
  read directionY: number,
  read directionZ: number,
  read distance: number?,
}

local loadError: unknown = ...

local PANEL_X, PANEL_Y, PANEL_Z = 0, 1.5, -1.5
local PANEL_HEIGHT = 0.9

local DEFAULT_ASPECT = 16 / 9

local NOTE_HEIGHT = 0.07

local ERROR_COLUMNS = 72
local ERROR_LINES = 5

local BEAM_LENGTH = 1.5

local RELOAD_KEY = 'f5'

-- The pointer ray follows the runtime's aim pose, which can differ from the controller pose.
local HANDS: { Hand } = {
  { pointer = 'hand/left/point', controller = 'hand/left' },
  { pointer = 'hand/right/point', controller = 'hand/right' },
}

-- A missing terminal reports `spawnFailed` as its process-exit outcome.
local TERMINALS = {
  { 'foot' },
  { 'weston-terminal' },
  { 'alacritty' },
  { 'kitty' },
  { 'konsole', '--separate' },
  { 'xterm' },
}

-- Opaque buffers use their fourth component as padding, so the fragment shader supplies full alpha.
local OPAQUE_FRAGMENT = [[
  vec4 lovrmain() {
    return vec4((Color * getPixel(ColorTexture, UV)).rgb, Color.a);
  }
]]

-- Graphics may be unavailable when safe mode runs without a graphics module.
local opaqueShader: Shader? = nil

local attempt = 0
local attempted: lunette.Process? = nil

-- A release goes to the sink that received the press, even after the pointer leaves it.
local pressed: { [number]: boolean? } = {}
local pressedSink: { [number]: lunette.Sink? } = {}

local function firstWindow(): lunette.Window?
  local window = lunette.windows()[1]
  if not window or window.dead then
    return nil
  end
  return window
end

local function panelSize(window: lunette.Window?): (number, number)
  local aspect = DEFAULT_ASPECT
  if window and window.width > 0 and window.height > 0 then
    aspect = window.width / window.height
  end
  return PANEL_HEIGHT * aspect, PANEL_HEIGHT
end

-- The panel's +y axis points up; surface pixels count +y downward.
local function hit(
  window: lunette.Window,
  originX: number,
  originY: number,
  originZ: number,
  directionX: number,
  directionY: number,
  directionZ: number
): (number?, number?, number?)
  if directionZ == 0 or window.width <= 0 or window.height <= 0 then
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

  return (x + width / 2) / width * window.width, (height / 2 - y) / height * window.height, distance
end

-- Error text wraps at fixed widths because paths and tracebacks lack useful word boundaries.
local function errorLines(text: unknown): { string }
  if not text then
    return {}
  end

  local lines: { string } = {}
  for paragraph in (tostring(text) .. '\n'):gmatch '([^\n]*)\n' do
    local remaining = paragraph
    repeat
      if #lines >= ERROR_LINES then
        lines[#lines + 1] = '…'
        return lines
      end
      lines[#lines + 1] = remaining:sub(1, ERROR_COLUMNS)
      remaining = remaining:sub(ERROR_COLUMNS + 1)
    until #remaining == 0
  end
  return lines
end

local errorText = errorLines(loadError)

local function spawnNextTerminal()
  attempt = attempt + 1
  local argv = TERMINALS[attempt]
  if not argv then
    attempted = nil
    print 'lunette: safe mode found no terminal emulator to spawn'
    return
  end

  attempted = lunette.spawn { argv = argv }
end

local function updateHand(index: number, hand: Hand, window: lunette.Window?): Beam?
  local headset = lovr.headset
  if not headset.isTracked(hand.pointer) then
    -- When tracking stops, release the held button so the client does not retain a press.
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

-- Beams use the same hand pose as the hit test, before the next frame updates it.
local beams: { Beam } = {}

function lovr.load()
  if lovr.graphics then
    opaqueShader = lovr.graphics.newShader('unlit', OPAQUE_FRAGMENT)
  end
  spawnNextTerminal()
end

lunette.onProcessExited(function(event: lunette.ProcessExitedEvent)
  if not attempted or event.process.id ~= attempted.id then
    return
  end

  if event.outcome == 'spawnFailed' then
    spawnNextTerminal()
  else
    attempted = nil
  end
end)

function lovr.keypressed(key: KeyCode)
  if key ~= RELOAD_KEY then
    return
  end

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
    -- The beam list stays dense because `ipairs` stops at the first missing index.
    local aimed = updateHand(index, hand, window)
    if aimed then
      beams[#beams + 1] = aimed
    end
  end
end

function lovr.draw(pass: Pass)
  local window = firstWindow()

  local top = PANEL_Y + PANEL_HEIGHT / 2 + NOTE_HEIGHT * (#errorText + 1)
  pass:text(
    'lunette: safe mode. The configuration did not load. Press ' .. RELOAD_KEY .. ' to try again.',
    PANEL_X,
    top,
    PANEL_Z,
    NOTE_HEIGHT
  )

  for index, line in ipairs(errorText) do
    pass:text(line, PANEL_X, top - index * NOTE_HEIGHT, PANEL_Z, NOTE_HEIGHT * 0.7)
  end

  -- Textures rotate with the client's buffers and remain false until the first commit.
  local texture = window and window:getTexture() or nil
  if texture then
    local width, height = panelSize(window)
    -- Client buffers use premultiplied alpha, which requires the matching blend mode.
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
