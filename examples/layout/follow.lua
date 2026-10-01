-- A follow-me layout: windows on an arc around the head that turns with the
-- user, lazily.
--
-- The layout is continuous, so the arranging consumer applies it on every
-- frame. The arc stays put while the head turns a little, and once the head
-- has turned further than `threshold` radians away from it, it swings round
-- to face the way the head faces. It reuses the arc layout's geometry, with
-- the head as the centre.
--
-- The options are `distance`, the arc's radius in metres; `threshold`, in
-- radians; and `speed`, how quickly the arc catches up, per second.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local geometry = require '@lunette-plugins/layout/arc/geometry'

export type Options = {
  read distance: number,
  read threshold: number,
  read speed: number,
}

local DEFAULTS: Options = { distance = 1.4, threshold = 0.6, speed = 4 }

-- When the arc has come this close to the head's heading, it stops turning.
local SETTLED = 0.02

-- The angle from `from` to `to`, between -pi and pi.
local function turn(from: number, to: number): number
  return (to - from + math.pi) % (2 * math.pi) - math.pi
end

local function follow(): ({ layouts.Panel }, unknown?) -> ()
  -- The arc's heading and whether it is catching up. The state is this
  -- registration's, so two registrations follow independently.
  local heading: number? = nil
  local turning = false
  return function(panels: { layouts.Panel }, given: unknown?): ()
    local options: Options = plugin.options { name = 'follow', defaults = DEFAULTS, config = given }
    local x, y, z = lovr.headset.getPosition 'head'
    local dx, _, dz = lovr.headset.getDirection 'head'
    local facing = math.atan2(-dx, -dz)
    local current = heading or facing
    local away = turn(current, facing)
    if math.abs(away) > options.threshold then
      turning = true
    end
    if turning then
      local step = math.min(1, options.speed * lovr.headset.getDeltaTime())
      current += away * step
      if math.abs(turn(current, facing)) < SETTLED then
        turning = false
      end
    end
    heading = current
    local widths: { number } = {}
    for index, panel in ipairs(panels) do
      widths[index] = panel.width or 0
    end
    local angles = geometry.angles(widths, {
      radius = options.distance,
      step = 0.3,
      span = math.pi,
      gap = 0.05,
      center = { x, y, z },
    })
    for index, angle in ipairs(angles) do
      local around = current + angle
      local pose = lovr.math
        .newMat4()
        :translate(x - math.sin(around) * options.distance, y, z - math.cos(around) * options.distance)
        :rotate(around, 0, 1, 0)
      layouts.setPose(panels[index], pose)
    end
  end
end

return plugin.define {
  name = 'follow-layout',
  requires = { layouts = layouts.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local service: layouts.Service = context:require(layouts.capability)
    service:register(context, { name = 'follow', apply = follow(), continuous = true })
  end,
}
