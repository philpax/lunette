-- The continuous layout applies every frame and turns the arc after the head exceeds `threshold` radians. Each registration keeps an independent heading.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'
local geometry = require '@lunette-plugins/layout/arc/geometry'

local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  distance = schema.default(schema.number())(1.4),
  threshold = schema.default(schema.number())(0.6),
  speed = schema.default(schema.number())(4),
}
export type Config = schema.Input<typeof(descriptor)>
export type Options = schema.Output<typeof(descriptor)>
local optionsSchema = schema.default(descriptor)(descriptor.parse {})

-- Rotation stops within this angular tolerance.
local SETTLED = 0.02

local function turn(from: number, to: number): number
  return (to - from + math.pi) % (2 * math.pi) - math.pi
end

local function follow(): ({ read [number]: layouts.Panel }, unknown?) -> ()
  -- Each registration keeps an independent heading and turn state.
  local heading: number? = nil
  local turning = false
  return function(panels: { read [number]: layouts.Panel }, given: unknown?): ()
    local options = optionsSchema.parse(given, 'follow')
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
    for index = 1, #panels do
      local panel = panels[index]
      widths[index] = panel.width or 0
    end
    local angles = geometry.angles(widths, {
      radius = options.distance,
      step = 0.3,
      span = math.pi,
      gap = 0.05,
      center = vector.pack(x, y, z),
    })
    for index, angle in ipairs(angles) do
      local around = current + angle
      local pose = lovr.math
        .newMat4()
        :translate(x - math.sin(around) * options.distance, y, z - math.cos(around) * options.distance)
        :rotate(around, 0, 1, 0)
      panels[index]:setPose(pose)
    end
  end
end

local consumerSchema = schema.object {}
type ConsumerConfig = schema.Input<typeof(consumerSchema)>
type ConsumerSettings = schema.Output<typeof(consumerSchema)>

return plugin.consumer<<ConsumerConfig, ConsumerSettings>>({
  name = 'follow-layout',
  requires = { layouts = layouts.capability },
  schema = consumerSchema,
  init = function(context: plugin.Context, _settings: ConsumerSettings)
    local service: layouts.Service = context:require(layouts.capability)
    service:register(context, { name = 'follow', apply = follow(), continuous = true })
  end,
}).definition
