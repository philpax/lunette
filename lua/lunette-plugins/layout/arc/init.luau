-- Registers a layout that arranges panels on an arc with the entry's tuning.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local geometry = require '@self/geometry'
local config = require '@self/config'

local arc = {}

export type Tuning = geometry.Tuning

export type Config = config.Config
export type Settings = config.Settings

local function headFrame(): Mat4?
  if not lovr.headset.isTracked 'head' then
    return nil
  end
  local x, y, z = lovr.headset.getPosition 'head'
  local fx, _, fz = lovr.headset.getDirection 'head'
  -- The arc stays upright even when the user looks down at the wrist menu.
  local yaw = if fx * fx + fz * fz > 1e-6 then math.atan2(-fx, -fz) else 0
  -- Centre height uses the default eye height as its reference.
  return lovr.math.newMat4():translate(x, y - 1.5, z):rotate(yaw, 0, 1, 0)
end

function arc.layout(tuning: Tuning, anchor: ('origin' | 'head')?): ({ read [number]: layouts.Panel }) -> ()
  return function(panels: { read [number]: layouts.Panel }): ()
    local widths: { number } = {}
    for index = 1, #panels do
      local panel = panels[index]
      widths[index] = panel.width or 0
    end
    local origin = if anchor == 'head' and #panels > 0 then headFrame() else nil
    for index, pose in ipairs(geometry.poses(widths, tuning)) do
      panels[index]:setPose(if origin then lovr.math.mat4(origin):mul(pose) else pose)
    end
  end
end

arc.definition = plugin.consumer<<Config, Settings>>({
  name = 'layout/arc',
  schema = config.schema,
  requires = { layouts.capability },
  init = function(context: plugin.Context, settings: Settings): ()
    local service: layouts.Service = context:require(layouts.capability)
    local head = settings.anchor == 'head'
      or (settings.anchor == 'auto' and lovr.system and lovr.system.getOS and lovr.system.getOS() == 'Windows')
    service:register(context, { name = settings.name, apply = arc.layout(settings.tuning, if head then 'head' else 'origin') })
  end,
}).definition

return table.freeze(arc)
