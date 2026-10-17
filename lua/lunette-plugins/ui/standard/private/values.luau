-- Value kinds: the slider, a continuous value with optional named detents.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'
local schema = require '@lunette-plugin/schema'
local keys = require '@lunette-contracts/keys'
local tokens = require './tokens'
local shapes = require './props'

local optional = schema.optional

local values = {}

local element = uiHost.element

-- A detent attracts values within this fraction of the range of it, and rounds those within the core to itself.
local ATTRACTION = 0.05
local CORE = 0.0125
-- The handle's width as a fraction of the theme's thumb size: a narrow upright key.
local HANDLE_WIDTH = 0.57
-- The handle grows by this factor about its centre while the slider is hovered or dragged, as the scroll bar's thumb
-- widens, so it is easier to keep a ray on.
local HANDLE_GROWTH = 1.25

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
  local thumb = node.theme.sizes.thumb * HANDLE_WIDTH
  local span = math.max(node.bounds.width - thumb, 1e-6)
  local t = math.clamp((x - thumb / 2) / span, 0, 1)
  local low, high = props.min or 0, props.max or 1
  local value = low + (high - low) * t
  if props.step and props.step > 0 then
    value = low + math.floor((value - low) / props.step + 0.5) * props.step
  end
  return math.clamp(value, low, high)
end

-- Draws a value towards a detent near it. Within the core the value rounds to the detent; across the rest of the
-- attraction it eases away, slowly near the detent and at the pointer's own rate at the edge, so the mapping is
-- continuous and increasing and every value around a detent stays reachable.
local function attract(props: uiHost.Props, value: number): number
  local range = (props.max or 1) - (props.min or 0)
  local reach, core = range * ATTRACTION, range * CORE
  for _, detent in props.detents or {} do
    local offset = value - detent.value
    local distance = math.abs(offset)
    if distance <= core then
      return detent.value
    elseif distance < reach then
      -- A cubic that leaves the core flat and meets the edge at the pointer's rate: h(1) = 1 and h'(1) is the band's
      -- share of the reach, so the slope against the pointer is 1 there.
      local t = (distance - core) / (reach - core)
      local share = (reach - core) / reach
      local a = 3 - share
      local eased = a * t * t + (1 - a) * t * t * t
      return detent.value + math.sign(offset) * reach * eased
    end
  end
  return value
end

-- Whether a move of the value from one position to another reaches or passes a notch: a detent, or on a stepped
-- slider, any other step. Leaving a detent is not a notch, so a drag off one ticks once, where it arrived.
local function notched(props: uiHost.Props, from: number, to: number): boolean
  if from == to then
    return false
  end
  if props.step and props.step > 0 then
    return true
  end
  local low, high = math.min(from, to), math.max(from, to)
  for _, detent in props.detents or {} do
    local value = detent.value
    if value ~= from and value >= low and value <= high then
      return true
    end
  end
  return false
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

-- The detents' names under the track, engraved at even spacing as the ticks are, with the current one in the accent.
-- A slider whose detents are not evenly spread has no row, since spaced names would not sit under their ticks.
local function detentLabels(props: uiHost.Props, current: any): uiHost.Element?
  local detents = props.detents
  if not detents or #detents < 2 then
    return nil
  end
  local low, high = props.min or 0, props.max or 1
  local spacing = (high - low) / (#detents - 1)
  local labels: { uiHost.Element } = {}
  for index, detent in detents do
    if math.abs(detent.value - (low + (index - 1) * spacing)) > spacing * 1e-3 then
      return nil
    end
    labels[index] = element('lunette/text', {
      key = `detent-{index}`,
      text = string.upper(detent.label),
      style = 'engraved',
      color = if current and detent.value == current.value then 'accent' else 'muted',
      wrap = false,
    })
  end
  return element('lunette/row', { key = 'detents', justify = 'space-between', labels })
end

function values.register(service: uiHost.Service, owner: any): { [string]: uiHost.Constructor }
  local constructors: { [string]: uiHost.Constructor } = {}
  -- The last value each held track previewed, which a notch is measured from. Several drag events can arrive before
  -- the track renders the previous one, so its value prop can lag behind.
  local previewed: { [uiHost.Node]: number } = setmetatable({}, { __mode = 'k' }) :: any

  service:registerKind(owner, {
    name = 'lunette/slider-track',
    props = shapes.disableable {
      value = optional(schema.number()),
      min = optional(schema.number()),
      max = optional(schema.number()),
      step = optional(schema.number()),
      detents = optional(schema.array(shapes.detent)),
      onPreview = optional(schema.callback(function(_value: number) end)),
      onFinish = optional(schema.callback(function(_value: number) end)),
      onCancel = optional(shapes.activate),
    },
    focus = 'pointer',
    engage = true,
    layout = {
      kind = 'leaf',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { height = theme.sizes.thumb + theme.spacing.sm, alignSelf = 'stretch' }
      end,
    },
    claims = { drag = 'x' },
    interactive = function(props: uiHost.Props): boolean
      return tokens.enabled(props)
    end,
    visuals = { 'lunette/slider-track' },
    event = function(node: uiHost.Node, event: uiHost.Event, base: (uiHost.Node, uiHost.Event) -> ())
      local kind = event.kind
      if kind == 'press' or kind == 'drag' then
        -- A detent draws the value towards it while the pointer is near, and the value moves freely between detents.
        local value = attract(node.props, valueAt(node, (event :: any).x))
        -- A drag ticks the holding pointer at each notch it reaches; the press has its own pulse.
        if kind == 'drag' and notched(node.props, previewed[node] or node.props.value or 0, value) then
          node:feedback 'detent'
        end
        previewed[node] = value
        node:emit('onPreview', value)
      elseif kind == 'release' then
        previewed[node] = nil
        node:emit('onFinish', attract(node.props, valueAt(node, (event :: any).x)))
      elseif kind == 'scroll' then
        -- Scroll arrives in logical pixels; a thousand of them sweep the whole range.
        local low, high = node.props.min or 0, node.props.max or 1
        local value = math.clamp(node.props.value + (event :: any).dx * (high - low) / 1000, low, high)
        node:emit('onFinish', value)
      elseif kind == 'cancel' then
        previewed[node] = nil
        node:emit 'onCancel'
      elseif kind == 'key' then
        -- Directions adjust the value from a keyboard at once, and from a controller only once traversal engaged the
        -- slider, so a controller user is never trapped in it.
        local key = event :: any
        local codes = keys.CODES
        local adjusts = node.state.engaged or key.source ~= 'controller'
        local direction = if key.code == codes.right or key.code == codes.up
          then 1
          elseif key.code == codes.left or key.code == codes.down then -1
          else 0
        if adjusts and direction ~= 0 then
          local low, high = node.props.min or 0, node.props.max or 1
          local step = node.props.step or (high - low) / 20
          node:emit('onFinish', math.clamp((node.props.value or low) + direction * step, low, high))
        else
          base(node, event)
        end
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
  service:registerVisual(owner, 'lunette/slider-track', function(node: uiHost.Node, draw: uiHost.Draw)
    local theme = node.theme
    local props = node.props
    local bounds = node.bounds
    -- The handle is ringed and marked down its centre in the accent.
    local thumbWidth = theme.sizes.thumb * HANDLE_WIDTH
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
    local mark = if enabled then theme.colors.accent else theme.colors.muted
    local growth = if active and enabled then HANDLE_GROWTH else 1
    local handleWidth, handleHeight = thumbWidth * growth, theme.sizes.thumb * growth
    local handle = {
      x = span * t + (thumbWidth - handleWidth) / 2,
      y = (bounds.height - handleHeight) / 2,
      width = handleWidth,
      height = handleHeight,
    }
    local lift = if node.state.dragging then theme.elevation.raised else theme.elevation.thumb
    draw:box(handle, {
      fill = if active then theme.colors.hover else theme.colors.raised,
      border = theme.sizes.edge * 2,
      borderColor = mark,
      radius = theme.radii.control,
      side = theme.colors.side,
      offset = lift,
      edges = true,
    })
    local line = theme.sizes.rule * 2
    local inset = handleWidth * 0.45
    draw:box({
      x = handle.x + (handleWidth - line) / 2,
      y = handle.y + inset,
      width = line,
      height = handle.height - 2 * inset,
    }, { fill = mark, offset = lift + theme.elevation.contentOffset })
  end)

  -- Slider props: label, value, min, max, step, detents, unit, onChange, and onCommit. While a drag is in progress,
  -- the dragged value is shown and reported through onChange; onCommit reports the released value. After a
  -- release the slider keeps showing the released value until the value prop changes.
  constructors.Slider = service:registerKind(owner, {
    name = 'lunette/slider',
    props = shapes.disableable {
      label = optional(schema.string()),
      value = optional(schema.number()),
      min = optional(schema.number()),
      max = optional(schema.number()),
      step = optional(schema.number()),
      detents = optional(schema.array(shapes.detent)),
      unit = optional(schema.string()),
      format = optional(schema.string()),
      onChange = optional(schema.callback(function(_value: number) end)),
      onCommit = optional(schema.callback(function(_value: number) end)),
    },
    role = 'slider',
    semantics = function(props: uiHost.Props, state: { read [string]: any }): uiHost.Semantics
      return { name = props.label, value = props.value, min = props.min or 0, max = props.max or 1 }
    end,
    layout = {
      kind = 'container',
      style = function(_props: uiHost.Props, theme: uiHost.Theme): lunette.LayoutStyle
        return { flexDirection = 'column', alignItems = 'stretch', gap = theme.spacing.xs }
      end,
    },
    state = { preview = false, pending = false, pendingFrom = false },
    expand = function(
      props: uiHost.Props,
      _children: { read [number]: uiHost.Element },
      state: { read [string]: any },
      act: uiHost.Actions
    ): uiHost.Child
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
          align = 'center',
          gap = 'sm',
          element('lunette/text', { key = 'label', text = props.label or '', style = 'body', grow = 1 }),
          -- The detent's name comes before the value, so the value and its unit keep their place at the end of the
          -- row whether or not the value sits on a detent.
          if detent
            then element(
              'lunette/text',
              { key = 'detent', text = string.upper(detent.label), style = 'engraved', color = 'accent' }
            )
            else nil,
          element('lunette/text', { key = 'value', text = readout, style = 'value', wrap = false }),
          if props.unit
            then element('lunette/text', { key = 'unit', text = props.unit, style = 'readout', color = 'muted' })
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
          -- A cancelled drag returns to the value prop and reports it, so a consumer that followed the preview
          -- returns too.
          onCancel = function()
            if state.preview ~= false then
              act.setState { preview = false }
              act.emit('onChange', props.value)
            end
          end,
        }),
        detentLabels(props, detent),
      }
    end,
  })

  return constructors
end

return values
