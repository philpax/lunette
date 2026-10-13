-- Creates a linear offscreen target and reads submitted pixels through LÖVR.

local render = {}

function render.target(width: number, height: number): (Texture, Pass)
  local texture = lovr.graphics.newTexture(width, height, {
    format = 'rgba8',
    linear = true,
    samples = 1,
    mipmaps = false,
    usage = { 'render', 'transfer' },
  })
  local pass = lovr.graphics.newPass { texture = texture, depth = false, samples = 1 }
  pass:setClear(0, 0, 0, 0)
  pass:setBlendMode(nil)
  return texture, pass
end

function render.read(texture: Texture, pass: Pass): Image
  lovr.graphics.submit(pass)
  local readback = texture:newReadback()
  lovr.graphics.submit {}
  readback:wait()
  assert(readback:isComplete(), 'graphics readback is incomplete after waiting')
  local image = readback:getImage()
  assert(image, 'graphics readback returned no image')
  return image
end

function render.baseline(): (Texture, Pass, Shader)
  local texture, pass = render.target(16, 8)
  local shader = lovr.graphics.newShader(
    'fill',
    [[
    vec4 lovrmain() {
      return UV.x < .5 ? vec4(.25, .5, .75, 1.) : vec4(.75, .25, .5, 1.);
    }
  ]]
  )
  pass:setShader(shader)
  pass:fill()
  return texture, pass, shader
end

return render
