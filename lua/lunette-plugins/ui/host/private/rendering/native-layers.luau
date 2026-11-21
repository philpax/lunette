-- Presents eligible toolkit panels as planar SteamVR overlays.

local records = require '../records'

local native = {}

type Held = { width: number, height: number, layer: Layer }
export type Cache = { [records.Panel]: Held }
export type Frame = {
  layers: { Layer },
  passes: { Pass },
  used: { [records.Panel]: boolean },
  limit: number,
}

function native.clear(cache: Cache, used: { [records.Panel]: boolean }?): ()
  for panel, held in cache do
    if not used or not used[panel] then
      cache[panel] = nil
      held.layer:release()
    end
  end
end

function native.begin(): Frame?
  local headset = lovr.headset
  if not headset or not headset.getDriver or headset.getDriver() ~= 'SteamVR' or not headset.isActive() then
    return nil
  end
  return { layers = headset.getLayers(), passes = {}, used = {}, limit = headset.getLayerLimit() }
end

local function pixels(metres: number): number
  return math.clamp(math.ceil(metres * 225) * 8, 16, 1536)
end

function native.prepare(cache: Cache, frame: Frame, panel: records.Panel): (Pass?, Layer?)
  local prefer = panel.options and panel.options.nativeLayer
  if panel.curve ~= 0 or #frame.layers >= frame.limit or not prefer or not prefer() then
    return nil, nil
  end

  local width, height = panel.width * panel.scale, panel.height * panel.scale
  local px, py = pixels(width), pixels(height)
  local held = cache[panel]
  if not held or held.width ~= px or held.height ~= py then
    local layer = lovr.headset.newLayer(px, py, { transparent = true })
    if held then
      held.layer:release()
    end
    held = { width = px, height = py, layer = layer }
    cache[panel] = held
  end
  local layer = held.layer
  layer:setPosition(panel.pose:getPosition())
  layer:setOrientation(panel.pose:getOrientation())
  layer:setDimensions(width, height)
  local pass = layer:getPass()
  pass:setViewPose(1, lovr.math.mat4(panel.pose):translate(0, 0, 1), false)
  -- Use Vulkan's Y direction and the same reversed depth as the scene's toolkit draws.
  pass:setProjection(1, lovr.math.mat4():orthographic(-width / 2, width / 2, height / 2, -height / 2, 2, 0.01))
  return pass, layer
end

function native.append(frame: Frame, panel: records.Panel, pass: Pass, layer: Layer): ()
  frame.used[panel] = true
  frame.layers[#frame.layers + 1] = layer
  frame.passes[#frame.passes + 1] = pass
end

function native.finish(cache: Cache, frame: Frame?): { Pass }?
  native.clear(cache, frame and frame.used)
  if frame and #frame.passes > 0 then
    lovr.headset.setLayers(frame.layers)
    return frame.passes
  end
  return nil
end

return native
