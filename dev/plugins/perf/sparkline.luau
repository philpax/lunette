-- A small line graph of a series, newest at the right edge, scaled so the largest sample sits below the top.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'

local sparkline = {}

local HEIGHT = 0.05
local LINE_WIDTH = 0.0012
-- Headroom above the largest sample, so a spike does not touch the edge.
local HEADROOM = 1.25

-- Props: values, oldest first, and capacity, the number of samples the full width holds.
function sparkline.register(host: uiHost.Service, owner: plugin.Owner): uiHost.Constructor
  local constructor = host:registerKind(owner, {
    name = 'dev/perf/sparkline',
    layout = {
      kind = 'container',
      style = function(): lunette.LayoutStyle
        return { height = HEIGHT, alignSelf = 'stretch', shrink = 0 }
      end,
    },
    visuals = { 'dev/perf/sparkline' },
  })
  host:registerVisual(owner, 'dev/perf/sparkline', function(node: uiHost.Node, draw: uiHost.Draw): ()
    local theme = node.theme
    local colors = theme.colors
    draw:box(nil, { fill = colors.sunken, radius = theme.radii.control })
    local values: { number } = node.props.values or {}
    local count = #values
    local capacity = math.max(node.props.capacity or count, count, 2)
    if count < 2 then
      return
    end
    local top = 0
    for _, value in values do
      top = math.max(top, value)
    end
    if top <= 0 then
      return
    end
    top *= HEADROOM
    local width, height = node.bounds.width, node.bounds.height
    local function point(index: number): (number, number)
      local x = width * (capacity - count + index - 1) / (capacity - 1)
      return x, height * (1 - values[index] / top)
    end
    local spec = { width = LINE_WIDTH, color = colors.accent, offset = theme.elevation.minimumSeparation }
    local x1, y1 = point(1)
    for index = 2, count do
      local x2, y2 = point(index)
      draw:line(x1, y1, x2, y2, spec)
      x1, y1 = x2, y2
    end
  end)
  return constructor
end

return sparkline
