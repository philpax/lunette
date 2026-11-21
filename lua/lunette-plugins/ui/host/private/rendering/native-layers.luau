-- Presents eligible toolkit panels as planar SteamVR overlays.

local records = require '../records'
local quad = require '@lunette-plugins/graphics/steamvr-quad'

local native = {}

export type Cache = { [records.Panel]: quad.Held }
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
  local layers = quad.layers()
  return if layers then { layers = layers, passes = {}, used = {}, limit = lovr.headset.getLayerLimit() } else nil
end

function native.prepare(cache: Cache, frame: Frame, panel: records.Panel): (Pass?, Layer?)
  local prefer = panel.options and panel.options.nativeLayer
  if panel.curve ~= 0 or #frame.layers >= frame.limit or (prefer and not prefer()) then
    return nil, nil
  end

  local width, height = panel.width * panel.scale, panel.height * panel.scale
  local held = quad.acquire(cache[panel], width, height)
  cache[panel] = held
  return quad.pass(held.layer, panel.pose, width, height), held.layer
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
