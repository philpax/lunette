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
