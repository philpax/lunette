-- Display kinds: text in a type role and colour role, and progress bars.

local uiHost = require '@lunette-contracts/ui-host'
local tokens = require './tokens'

local display = {}

function display.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  -- Text props: text, style (a type role), color (a colour role or a colour), align, wrap, maxLines, and grow.
  constructors.Text = service:registerKind(owner, {
    name = 'lunette/text',
    layout = {
      kind = 'text',
      text = function(props)
        return tostring(props.text or '')
      end,
      style = function(props)
        return { grow = props.grow, shrink = props.shrink, basis = props.basis, alignSelf = props.alignSelf }
      end,
      textStyle = function(props, theme)
        return tokens.textStyle(theme, props.style, {
          align = props.align,
          wrap = if props.wrap == false then 'none' else nil,
          maxLines = props.maxLines,
        })
      end,
    },
    visuals = { 'lunette/text' },
  })
  service:registerVisual(owner, 'lunette/text', function(node, draw)
    draw:text { color = tokens.ink(node.theme, node.props.color) }
  end)

  -- Progress bars are square-cut: a sunken rail and an accent fill for the value from 0 to 1.
  constructors.Progress = service:registerKind(owner, {
    name = 'lunette/progress',
    layout = {
      kind = 'leaf',
      style = function(props, theme)
        return { height = theme.sizes.rail * 1.5, alignSelf = 'stretch', grow = props.grow, width = props.width }
      end,
    },
    visuals = { 'lunette/progress' },
  })
  service:registerVisual(owner, 'lunette/progress', function(node, draw)
    local theme = node.theme
    local bounds = node.bounds
    local value = math.clamp(tonumber(node.props.value) or 0, 0, 1)
    draw:box(nil, { fill = theme.colors.rail })
    if value > 0 then
      draw:box({ x = 0, y = 0, width = bounds.width * value, height = bounds.height }, { fill = theme.colors.accent })
    end
  end)

  return constructors
end

return display
