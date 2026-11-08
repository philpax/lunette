-- Copies resolved multiview layers into separate 2D textures through the public transfer API.
local overlay = {}
export type Keep = <T>(T & { release: (any) -> () }) -> T

function overlay.layers(source: Texture, keep: Keep): { Texture }
  local width, height, layers = source:getDimensions()
  assert(source:getType() == 'array' and layers == 2, 'overlay copy source is a two-layer array')
  assert(source:getSampleCount() == 1, 'overlay copies use the resolved single-sample array')
  local format, linear = source:getFormat()
  local outputs = {}
  for eye = 1, 2 do
    local texture = keep(lovr.graphics.newTexture(width, height, {
      type = '2d',
      format = format,
      linear = linear,
      samples = 1,
      mipmaps = false,
      usage = { 'transfer' },
    }))
    -- Equal extents and formats select lovrTextureCopy, rather than a scaled or filtered blit.
    texture:setPixels(source, 0, 0, 1, 1, 0, 0, eye, 1, width, height, 1)
    assert(texture:getType() == '2d' and texture:getLayerCount() == 1, 'each overlay has a separate 2D texture')
    outputs[eye] = texture
  end
  assert(outputs[1] ~= outputs[2], 'overlay eyes do not alias one texture')
  return outputs
end

function overlay.image(readback: Readback, keep: Keep): Image
  readback:wait()
  assert(readback:isComplete(), 'overlay readback completes')
  local image = readback:getImage()
  assert(image, 'overlay readback returns an image')
  return keep(image)
end

function overlay.identical(actual: Image, expected: Image, label: string): ()
  local width, height = actual:getDimensions()
  assert(width == expected:getWidth() and height == expected:getHeight(), label .. ': image dimensions agree')
  local maximum = 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local ar, ag, ab, aa = actual:getPixel(x, y)
      local er, eg, eb, ea = expected:getPixel(x, y)
      maximum = math.max(maximum, math.abs(ar - er), math.abs(ag - eg), math.abs(ab - eb), math.abs(aa - ea))
    end
  end
  assert(maximum == 0, string.format('%s: full-image RGBA copy error %.9g', label, maximum))
end

return overlay
