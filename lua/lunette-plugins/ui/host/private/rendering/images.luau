-- Textures for image sources. SVG documents are rasterised natively at the size they are drawn, rounded up to a size
-- class so a small change of size does not rasterise again; files are read once. Textures unused for a while are
-- released.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'

local images = {}

-- Pixels per metre an SVG is rasterised at: two pixels per millimetre, sharp at arm's length.
local PIXELS_PER_METRE = 2000
-- Size classes step by a quarter, so an image re-rasterises only when its drawn size changes by that much.
local CLASS_STEP = 1.25
local LIMIT = 2048
-- Frames a texture survives without being drawn.
local IDLE_FRAMES = 300

type Entry = { texture: Texture, used: number }

export type Cache = {
  entries: { [string]: Entry },
  frame: number,
}

function images.new(): Cache
  return { entries = {}, frame = 0 }
end

local function sizeClass(metres: number): number
  local pixels = math.clamp(metres * PIXELS_PER_METRE, 1, LIMIT)
  local class = 16
  while class < pixels and class < LIMIT do
    class = math.ceil(class * CLASS_STEP)
  end
  return math.min(class, LIMIT)
end

local function fresh(cache: Cache, key: string, create: () -> Texture): Texture
  local entry = cache.entries[key]
  if not entry then
    entry = { texture = create(), used = cache.frame }
    cache.entries[key] = entry
  end
  entry.used = cache.frame
  return entry.texture
end

-- The texture to draw a source with at a size in metres. A source that cannot be read or rasterised raises, and the
-- panel's draw reports it.
function images.texture(cache: Cache, source: uiHost.ImageSource, width: number, height: number): Texture
  if source.kind == 'texture' then
    return source.texture
  elseif source.kind == 'file' then
    return fresh(cache, 'file:' .. source.path, function(): Texture
      return lovr.graphics.newTexture(source.path, { mipmaps = true })
    end)
  end
  local pixelsWide, pixelsHigh = sizeClass(width), sizeClass(height)
  local key = `svg:{pixelsWide}x{pixelsHigh}:{source.data}`
  return fresh(cache, key, function(): Texture
    local pixels, w, h = lunette.rasterizeSvg(source.data, pixelsWide, pixelsHigh)
    local image = lovr.data.newImage(w, h, 'rgba8', lovr.data.newBlob(pixels, 'svg'))
    return lovr.graphics.newTexture(image, { mipmaps = true })
  end)
end

-- Advances the frame and releases textures that have not been drawn recently.
function images.collect(cache: Cache): ()
  cache.frame += 1
  for key, entry in cache.entries do
    if cache.frame - entry.used > IDLE_FRAMES then
      entry.texture:release()
      cache.entries[key] = nil
    end
  end
end

function images.release(cache: Cache): ()
  for _, entry in cache.entries do
    entry.texture:release()
  end
  table.clear(cache.entries)
end

return images
