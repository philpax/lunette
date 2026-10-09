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
export type Settings = schema.Output<typeof(descriptor)>

local function grid(panels: { read [number]: layouts.Panel }, options: Settings): ()
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

return plugin.consumer<<Config, Settings>> {
  name = 'grid-layout',
  requires = { layouts.capability },
  schema = descriptor,
  init = function(context: plugin.Context, settings: Settings)
    local service: layouts.Service = context:require(layouts.capability)
    -- The registration ends with the plugin activation.
    service:register(context, {
      name = 'grid',
      apply = function(panels: { read [number]: layouts.Panel }): ()
        grid(panels, settings)
      end,
    })
  end,
}
