-- The grid layout is independent of the consumer that selects its panels and invocation time.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'

local schema = require '@lunette-plugin/schema'

local descriptor = schema.object {
  columns = schema.default(schema.number { minimum = 0, integer = true })(0),
  gap = schema.default(schema.number())(0.08),
  center = schema.default(schema.vector())(vector.pack(0, 1.5, -1.8)),
}
export type Config = schema.Input<typeof(descriptor)>
export type Options = schema.Output<typeof(descriptor)>
local optionsSchema = schema.default(descriptor)(descriptor.parse {})

local function resolve(given: unknown): Options
  return optionsSchema.parse(given, 'grid')
end

local function grid(panels: { read [number]: layouts.Panel }, given: unknown?): ()
  local options = resolve(given)
  local count = #panels
  if count == 0 then
    return
  end
  local columns = if options.columns > 0 then options.columns else math.ceil(math.sqrt(count))
  local rows = math.ceil(count / columns)
  -- Every cell uses the largest panel dimensions to keep the grid aligned.
  local cellWidth, cellHeight = 0, 0
  for index = 1, count do
    local panel = panels[index]
    cellWidth = math.max(cellWidth, panel.width or 0)
    cellHeight = math.max(cellHeight, panel.height or 0)
  end
  cellWidth += options.gap
  cellHeight += options.gap
  local center = options.center
  for index = 1, count do
    local panel = panels[index]
    local column = (index - 1) % columns
    local row = (index - 1) // columns
    local offset = vector.pack((column - (columns - 1) / 2) * cellWidth, ((rows - 1) / 2 - row) * cellHeight, 0)
    panel:setPose(lovr.math.newMat4():translate(center + offset))
  end
end

type ConsumerConfig = {}
type ConsumerSettings = {}

return plugin.consumer<<ConsumerConfig, ConsumerSettings>>({
  name = 'grid-layout',
  requires = { layouts.capability },
  init = function(context: plugin.Context, _settings: ConsumerSettings)
    local service: layouts.Service = context:require(layouts.capability)
    -- The registration ends with the plugin activation.
    service:register(context, { name = 'grid', apply = grid })
  end,
}).definition
