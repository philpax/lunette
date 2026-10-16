-- The Markdown view: a composite kind that parses its source and expands into standard kinds, and the small kinds
-- it needs for inline spans, word flows, quotes, code blocks, and table rows.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local tokens = require './tokens'
local parse = require '@self/parse'
local render = require '@self/render'

local markdown = {}

-- Activation reaches `onActivate`; presses and hover stay with the span, which draws its own hover state.
local function activateOnly(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ()): ()
  if event.kind == 'activate' then
    node:emit 'onActivate'
  elseif
    event.kind ~= 'press'
    and event.kind ~= 'release'
    and event.kind ~= 'hover-enter'
    and event.kind ~= 'hover-leave'
  then
    base(node, event)
  end
end

local function registerInline(service: uiHost.Service, owner: any): ()
  -- One word or piece of a word in one style: text, style (a type role), color, code, and onActivate for a link.
  service:registerKind(owner, {
    name = 'lunette/markdown-span',
    layout = {
      kind = 'text',
      text = function(props: uiHost.Props): string
        return tostring(props.text or '')
      end,
      textStyle = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutTextStyle
        -- A word longer than the line breaks between glyphs rather than overflowing.
        return tokens.textStyle(theme, props.style, { wrap = 'word-or-glyph' })
      end,
    },
    interactive = function(props: uiHost.Props): boolean
      return props.onActivate ~= nil
    end,
    event = activateOnly,
    visuals = { 'lunette/markdown-span' },
  })
  service:registerVisual(owner, 'lunette/markdown-span', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    if node.props.code then
      local pad = theme.spacing.xs * 0.5
      draw:box(
        { x = -pad, y = 0, width = bounds.width + pad * 2, height = bounds.height },
        { fill = theme.colors.sunken, radius = theme.radii.control * 0.5 }
      )
    end
    draw:text { color = tokens.ink(theme, node.props.color), offset = theme.elevation.minimumSeparation }
    if node.props.onActivate and node.state.hovered then
      local height = theme.sizes.underline
      draw:box(
        { x = 0, y = bounds.height - height, width = bounds.width, height = height },
        { fill = theme.colors.accent, offset = theme.elevation.minimumSeparation }
      )
    end
  end)

  -- A line of words that wraps between them: style (the body's type role, which sets the word gap) and align.
  service:registerKind(owner, {
    name = 'lunette/markdown-flow',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        local justify = props.align
        return {
          flexDirection = 'row',
          wrap = 'wrap',
          alignItems = 'baseline',
          justifyContent = if justify == 'center' then 'center' elseif justify == 'end' then 'end' else 'start',
          -- About the width of a space in the text's face.
          columnGap = tokens.typography(theme, props.style).size * 0.28,
          rowGap = 0,
        }
      end,
    },
  })
end

local function registerBlocks(service: uiHost.Service, owner: any): ()
  service:registerKind(owner, {
    name = 'lunette/markdown-quote',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          gap = theme.spacing.md,
          padding = { left = theme.spacing.md + theme.sizes.underline * 2 },
        }
      end,
    },
    visuals = { 'lunette/markdown-quote' },
  })
  service:registerVisual(owner, 'lunette/markdown-quote', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local width = theme.sizes.underline * 2
    draw:box({ x = 0, y = 0, width = width, height = node.bounds.height }, { fill = theme.colors.line })
  end)

  -- Code keeps its line breaks and is clipped to the block rather than overflowing the panel.
  service:registerKind(owner, {
    name = 'lunette/markdown-code',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', padding = theme.spacing.md }
      end,
    },
    clip = true,
    visuals = { 'lunette/markdown-code' },
  })
  service:registerVisual(owner, 'lunette/markdown-code', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    draw:box(nil, {
      fill = theme.colors.sunken,
      radius = theme.radii.control,
      border = theme.sizes.rule,
      borderColor = theme.colors.line,
    })
  end)

  -- A body row of a table, laid out as the table header is, so the columns line up.
  service:registerKind(owner, {
    name = 'lunette/markdown-table-row',
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'row',
          alignItems = 'start',
          gap = theme.spacing.md,
          padding = {
            left = theme.spacing.md,
            right = theme.spacing.md,
            top = theme.spacing.xs,
            bottom = theme.spacing.xs,
          },
        }
      end,
    },
    visuals = { 'lunette/markdown-table-row' },
  })
  service:registerVisual(owner, 'lunette/markdown-table-row', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local bounds = node.bounds
    -- As thick as a separator.
    local rule = theme.sizes.rule * 2
    draw:box({ x = 0, y = bounds.height - rule, width = bounds.width, height = rule }, { fill = theme.colors.line })
  end)

  -- Every cell takes an equal share of its row.
  service:registerKind(owner, {
    name = 'lunette/markdown-cell',
    layout = {
      kind = 'container',
      style = function(): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', grow = 1, shrink = 1, basis = 0, minWidth = 0 }
      end,
    },
  })
end

function markdown.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}
  registerInline(service, owner)
  registerBlocks(service, owner)

  -- Markdown props: source (a Markdown string), onLink (receives a link's target), and gap.
  constructors.Markdown = service:registerKind(owner, {
    name = 'lunette/markdown',
    layout = {
      kind = 'container',
      style = function(props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return {
          flexDirection = 'column',
          alignItems = 'stretch',
          gap = tokens.space(theme, props.gap, theme.spacing.md),
          grow = props.grow,
        }
      end,
    },
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      _state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
      local tree = parse.document(tostring(props.source or ''))
      return render.document(tree, function(target: string)
        act.emit('onLink', target)
      end)
    end,
  })

  return constructors
end

return markdown
