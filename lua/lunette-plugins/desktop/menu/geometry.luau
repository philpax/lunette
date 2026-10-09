-- The panel and its public description use the same wrist and logical control geometry.
local ui = require '@lunette-contracts/ui'
local config = require './config'

local geometry = {}

export type Layout = {
  read width: number,
  read height: number,
  read logicalWidth: number,
  read logicalHeight: number,
  read button: ui.Bounds,
  read actions: ui.Bounds?,
}

function geometry.layout(settings: config.Settings, opened: boolean): Layout
  if not opened then
    return {
      width = settings.size,
      height = settings.size,
      logicalWidth = 100,
      logicalHeight = 100,
      button = { x = 0, y = 0, width = 100, height = 100 },
    }
  end
  local expanded = settings.expanded
  return {
    width = expanded.width,
    height = expanded.height,
    logicalWidth = expanded.logicalWidth,
    logicalHeight = expanded.logicalHeight,
    button = { x = 8, y = 8, width = expanded.logicalWidth - 16, height = 40 },
    actions = {
      x = 8,
      y = 8,
      width = expanded.logicalWidth - 16,
      height = expanded.logicalHeight - 16,
    },
  }
end

function geometry.pose(device: Device, offset: vector): Mat4
  local x, y, z, angle, ax, ay, az = lovr.headset.getPose(device)
  local pose = lovr.math.newMat4(x, y, z, angle, ax, ay, az)
  return pose:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
end

return geometry
