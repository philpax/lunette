-- Owns the stereo curtain target and records its camera copy and premultiplied composite.
local plugin = require '@lunette-plugin'
local cleanup = require '@lunette-plugins/lifecycle/cleanup'

local halfResolution = {}
export type Target = {
  read pass: Pass,
  read texture: Texture,
  read width: number,
  read height: number,
  read sampler: Sampler,
  read shader: Shader,
}
export type Renderer = {
  read prepare: (Pass) -> Target?,
  read composite: (Pass, Target) -> (),
}
type OwnedTarget = {
  read target: Target,
  read effect: plugin.Effect,
}
local configure: (Target, Pass) -> ()
local VERTEX = [[
vec4 lovrmain() {
  vec2 position = vec2((VertexIndex << 1) & 2, VertexIndex & 2);
  UV = position;
  return vec4(position * 2. - 1., 0., 1.);
}
]]
local FRAGMENT = [[
uniform texture2DArray curtainTexture;
uniform sampler curtainSampler;
vec4 lovrmain() {
  vec4 curtain = texture(sampler2DArray(curtainTexture, curtainSampler), vec3(UV, ViewIndex));
  // Zero alpha can still carry emitted light, so only entirely empty pixels skip blending.
  if (all(equal(curtain, vec4(0.)))) discard;
  return curtain;
}
]]

local function acquire(context: plugin.Context, width: number, height: number): OwnedTarget
  local target: Target? = nil
  local effect = context:effect(function(): () -> ()
    local releases: { () -> () } = {}
    local ok, failure = pcall(function(): ()
      local texture = lovr.graphics.newTexture(width, height, 2, {
        type = 'array',
        format = 'rgba16f',
        linear = true,
        samples = 1,
        mipmaps = false,
        usage = { 'render', 'sample' },
      })
      table.insert(releases, 1, function(): ()
        texture:release()
      end)
      local sampler = lovr.graphics.newSampler { filter = 'linear', wrap = 'clamp', mipmaprange = { 0, 0 } }
      table.insert(releases, 1, function(): ()
        sampler:release()
      end)
      local shader = lovr.graphics.newShader(VERTEX, FRAGMENT, { label = 'desktop/backdrop curtain composite' })
      table.insert(releases, 1, function(): ()
        shader:release()
      end)
      local pass = lovr.graphics.newPass()
      table.insert(releases, 1, function(): ()
        pass:release()
      end)
      target = { pass = pass, texture = texture, sampler = sampler, shader = shader, width = width, height = height }
    end)
    if not ok then
      local cleaned, cleanupFailure = pcall(cleanup.run, 'backdrop half-resolution acquisition', releases)
      if not cleaned then
        error(tostring(failure) .. '; ' .. tostring(cleanupFailure), 0)
      end
      error(failure, 0)
    end
    return function(): ()
      cleanup.run('backdrop half-resolution resources', releases)
    end
  end)
  assert(target, 'backdrop: half-resolution acquisition did not complete')
  return { target = target, effect = effect }
end

function halfResolution.new(context: plugin.Context): Renderer
  local owned: OwnedTarget? = nil
  return table.freeze {
    prepare = function(main: Pass): Target?
      if not context:active() then
        return nil
      end
      local width, height = main:getWidth(), main:getHeight()
      if width < 960 or height < 640 or main:getViewCount() ~= 2 then
        return nil
      end
      local canvas = main:getCanvas()
      if not canvas or (canvas.samples ~= 1 and canvas.samples ~= 4) then
        return nil
      end
      local linear = lovr.graphics.isFormatSupported('rgba16f', 'render', 'sample')
      if not linear then
        return nil
      end
      -- The minimum keeps narrow curtain strands resolved on smaller stereo canvases.
      local scale = math.max(0.5, 720 / width, 480 / height)
      local targetWidth = math.ceil(width * scale)
      local targetHeight = math.ceil(height * scale)
      local previous = owned
      if previous and previous.target.width == targetWidth and previous.target.height == targetHeight then
        configure(previous.target, main)
        return previous.target
      end
      local replacement = acquire(context, targetWidth, targetHeight)
      local ok, failure = pcall(function(): ()
        configure(replacement.target, main)
      end)
      if not ok then
        local cleaned, cleanupFailure = pcall(function(): ()
          replacement.effect:dispose()
        end)
        if not cleaned then
          error(tostring(failure) .. '; ' .. tostring(cleanupFailure), 0)
        end
        error(failure, 0)
      end
      owned = replacement
      if previous then
        previous.effect:dispose()
      end
      return replacement.target
    end,
    composite = function(main: Pass, target: Target): ()
      main:setShader(target.shader)
      main:send('curtainTexture', target.texture)
      main:send('curtainSampler', target.sampler)
      main:mesh(3)
    end,
  }
end

configure = function(target: Target, main: Pass): ()
  local pass = target.pass
  pass:reset()
  pass:setCanvas { texture = target.texture, depth = false, samples = 1 }
  pass:setClear(0, 0, 0, 0)
  pass:setViewport()
  pass:setScissor()
  for eye = 1, 2 do
    local projection = main:getProjection(eye, lovr.math.mat4())
    local pose = main:getViewPose(eye, lovr.math.mat4(), false)
    pass:setProjection(eye, projection)
    pass:setViewPose(eye, pose, false)
  end
end

return halfResolution
