-- The grid layout is independent of the consumer that selects its panels and invocation time.

local plugin = require '@lunette-plugin'
local layouts = require '@lunette-contracts/layouts'

export type Options = {
  read columns: number,
  read gap: number,
  read center: { number },
}

local DEFAULTS: Options = { columns = 0, gap = 0.08, center = { 0, 1.5, -1.8 } }

local function resolve(given: unknown): Options
  local options: Options = plugin.options { name = 'grid', defaults = DEFAULTS, config = given }
  local columns = options.columns
  if columns < 0 or columns ~= math.floor(columns) then
    error('plugin grid: option columns is a whole number of at least 0, not ' .. tostring(columns), 0)
  end
  if #options.center ~= 3 then
    error('plugin grid: option center is three numbers', 0)
  end
  return options
end

local function grid(panels: { layouts.Panel }, given: unknown?): ()
  local options = resolve(given)
  local count = #panels
  if count == 0 then
    return
  end
  local columns = if options.columns > 0 then options.columns else math.ceil(math.sqrt(count))
  local rows = math.ceil(count / columns)
  -- Every cell uses the largest panel dimensions to keep the grid aligned.
  local cellWidth, cellHeight = 0, 0
  for _, panel in ipairs(panels) do
    cellWidth = math.max(cellWidth, panel.width or 0)
    cellHeight = math.max(cellHeight, panel.height or 0)
  end
  cellWidth += options.gap
  cellHeight += options.gap
  local center = options.center
  for index, panel in ipairs(panels) do
    local column = (index - 1) % columns
    local row = (index - 1) // columns
    local x = center[1] + (column - (columns - 1) / 2) * cellWidth
    local y = center[2] + ((rows - 1) / 2 - row) * cellHeight
    panel:setPose(lovr.math.newMat4():translate(x, y, center[3]))
  end
end

return plugin.define {
  name = 'grid-layout',
  requires = { layouts = layouts.capability },
  init = function(context: plugin.Context, _config: {}, _publish: plugin.Publisher)
    local service: layouts.Service = context:require(layouts.capability)
    -- The registration ends with the plugin activation.
    service:register(context, { name = 'grid', apply = grid })
  end,
}
