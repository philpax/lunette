-- Draws a world-space rectangle into a caller-owned SteamVR overlay.

local quad = {}

export type Held = { width: number, height: number, layer: Layer }

function quad.layers(): { Layer }?
  local headset = lovr.headset
  if headset and headset.getDriver and headset.getDriver() == 'SteamVR' and headset.isActive() then
    return headset.getLayers()
  end
  return nil
end

local function pixels(metres: number): number
  return math.clamp(math.ceil(metres * 225) * 8, 16, 1536)
end

function quad.acquire(held: Held?, width: number, height: number): Held
  local px, py = pixels(width), pixels(height)
  if held and held.width == px and held.height == py then
    return held
  end
  local layer = lovr.headset.newLayer(px, py, { transparent = true })
  if held then
    held.layer:release()
  end
  return { width = px, height = py, layer = layer }
end

function quad.pass(layer: Layer, pose: Mat4, width: number, height: number): Pass
  layer:setPosition(pose:getPosition())
  layer:setOrientation(pose:getOrientation())
  layer:setDimensions(width, height)
  local pass = layer:getPass()
  pass:setViewPose(1, lovr.math.mat4(pose):translate(0, 0, 1), false)
  -- Use Vulkan's Y direction and the same reversed depth as the scene draws.
  pass:setProjection(1, lovr.math.mat4():orthographic(-width / 2, width / 2, height / 2, -height / 2, 2, 0.01))
  return pass
end

return quad
