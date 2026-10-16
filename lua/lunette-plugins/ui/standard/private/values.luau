-- Value kinds: the slider, a continuous value with optional named detents.

local uiHost = require '@lunette-contracts/ui-host'
local tokens = require './tokens'

local values = {}

local element = uiHost.element

-- A released value within this fraction of the range from a detent snaps to it.
local SNAP = 0.04

local function fraction(props: uiHost.Props, value: number): number
  local low, high = props.min or 0, props.max or 1
  if high <= low then
    return 0
  end
  return math.clamp((value - low) / (high - low), 0, 1)
end

-- The value under a position on the rail, which spans the track's width less the thumb.
local function valueAt(node: uiHost.Node, x: number): number
  local props = node.props
  local thumb = node.theme.sizes.thumb * 0.7
  local span = math.max(node.bounds.width - thumb, 1e-6)
  local t = math.clamp((x - thumb / 2) / span, 0, 1)
  local low, high = props.min or 0, props.max or 1
  local value = low + (high - low) * t
  if props.step and props.step > 0 then
    value = low + math.floor((value - low) / props.step + 0.5) * props.step
  end
  return math.clamp(value, low, high)
end

local function snap(props: uiHost.Props, value: number): number
  local range = (props.max or 1) - (props.min or 0)
  for _, detent in props.detents or {} do
    if math.abs(detent.value - value) <= range * SNAP then
      return detent.value
    end
  end
  return value
end

-- The detent at the value, if the value sits on one.
local function detentAt(props: uiHost.Props, value: number): any
  for _, detent in props.detents or {} do
    if math.abs(detent.value - value) < 1e-9 then
      return detent
    end
  end
  return nil
end

function values.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}

  service:registerKind(owner, {
    name = 'lunette/slider-track',
    layout = {
      kind = 'leaf',
      style = function(_props, theme)
        return { height = theme.sizes.thumb + theme.spacing.sm, alignSelf = 'stretch' }
      end,
    },
    claims = { drag = 'x' },
    interactive = function(props)
      return tokens.enabled(props)
    end,
    visuals = { 'lunette/slider-track' },
    event = function(node, event, base)
      local kind = event.kind
      if kind == 'press' or kind == 'drag' then
        node:emit('onPreview', valueAt(node, (event :: any).x))
      elseif kind == 'release' then
        node:emit('onFinish', snap(node.props, valueAt(node, (event :: any).x)))
      elseif kind == 'scroll' then
        local step = node.props.step or ((node.props.max or 1) - (node.props.min or 0)) / 20
        local value = math.clamp(node.props.value + (event :: any).dx * step, node.props.min or 0, node.props.max or 1)
        node:emit('onFinish', value)
      elseif
        kind ~= 'hover-enter'
        and kind ~= 'hover-leave'
        and kind ~= 'activate'
        and kind ~= 'drag-start'
        and kind ~= 'drag-end'
      then
        base(node, event)
      end
    end,
  })
  service:registerVisual(owner, 'lunette/slider-track', function(node, draw)
    local theme = node.theme
    local props = node.props
    local bounds = node.bounds
    local thumbWidth = theme.sizes.thumb * 0.7
    local span = bounds.width - thumbWidth
    local rail = theme.sizes.rail
    local railY = bounds.height / 2 - rail / 2
    local t = fraction(props, props.value or 0)
    local enabled = tokens.enabled(props)
    -- Rails are square-cut.
    draw:box({ x = thumbWidth / 2, y = railY, width = span, height = rail }, { fill = theme.colors.rail })
    if t > 0 then
      draw:box({ x = thumbWidth / 2, y = railY, width = span * t, height = rail }, {
        fill = if enabled then theme.colors.accent else theme.colors.muted,
      })
    end
    for _, detent in props.detents or {} do
      local at = thumbWidth / 2 + span * fraction(props, detent.value)
      local tick = theme.sizes.rule * 2
      local current = math.abs(detent.value - (props.value or 0)) < 1e-9
      draw:box(
        { x = at - tick / 2, y = railY + rail + theme.spacing.xs * 0.5, width = tick, height = theme.spacing.xs },
        {
          fill = if current then theme.colors.accent else theme.colors.line,
        }
      )
    end
    local active = node.state.hovered or node.state.dragging
    draw:box(
      { x = span * t, y = (bounds.height - theme.sizes.thumb) / 2, width = thumbWidth, height = theme.sizes.thumb },
      {
        fill = if active then theme.colors.hover else theme.colors.raised,
        radius = theme.radii.control,
        side = theme.colors.side,
        offset = if node.state.dragging then theme.elevation.raised else theme.elevation.thumb,
        edges = true,
      }
    )
  end)

  -- Slider props: label, value, min, max, step, detents, unit, onChange, and onCommit. While a drag is in progress,
  -- the dragged value is shown and reported through onChange; onCommit reports the released value. After a
  -- release the slider keeps showing the released value until the value prop changes.
  constructors.Slider = service:registerKind(owner, {
    name = 'lunette/slider',
    layout = {
      kind = 'container',
      style = function(_props, theme)
        return { flexDirection = 'column', alignItems = 'stretch', gap = theme.spacing.xs }
      end,
    },
    state = { preview = false, pending = false, pendingFrom = false },
    expand = function(props, _children, state, act)
      local shown = props.value or 0
      if state.preview ~= false then
        shown = state.preview
      elseif state.pending ~= false and props.value == state.pendingFrom then
        shown = state.pending
      end
      local detent = detentAt(props, shown)
      local readout = string.format(props.format or '%.2f', shown)
      return {
        element('lunette/row', {
          key = 'heading',
          align = 'baseline',
          gap = 'sm',
          element('lunette/text', { key = 'label', text = props.label or '', style = 'body', grow = 1 }),
          element('lunette/text', { key = 'value', text = readout, style = 'value', wrap = false }),
          if props.unit
            then element('lunette/text', { key = 'unit', text = props.unit, style = 'caption', color = 'muted' })
            else nil,
          if detent
            then element(
              'lunette/text',
              { key = 'detent', text = string.upper(detent.label), style = 'caption', color = 'accent' }
            )
            else nil,
        }),
        element('lunette/slider-track', {
          key = 'track',
          value = shown,
          min = props.min,
          max = props.max,
          step = props.step,
          detents = props.detents,
          disabledReason = props.disabledReason,
          onPreview = function(value: number)
            act.setState { preview = value }
            act.emit('onChange', value)
          end,
          onFinish = function(value: number)
            act.setState { preview = false, pending = value, pendingFrom = props.value }
            act.emit('onChange', value)
            act.emit('onCommit', value)
          end,
        }),
      }
    end,
  })

  return constructors
end

return values
