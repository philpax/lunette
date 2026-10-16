-- Resolves the standard kinds' token-valued props against the theme.

local lunette = require '@lunette'
local uiHost = require '@lunette-contracts/ui-host'

local tokens = {}

-- A spacing token name or metres.
function tokens.space(theme: uiHost.Theme, value: any, fallback: number?): number
  if value == nil then
    return fallback or 0
  end
  if type(value) == 'number' then
    return value
  end
  local found = (theme.spacing :: any)[value]
  assert(type(found) == 'number', `ui: '{tostring(value)}' is not a spacing token`)
  return found
end

-- A text colour role, or a colour.
function tokens.ink(theme: uiHost.Theme, value: any, fallback: uiHost.Color?): uiHost.Color
  if value == nil then
    return fallback or theme.colors.ink
  end
  if type(value) == 'table' then
    return value
  end
  -- Accent text takes the accent guarded for text, so it stays readable on the surface in both modes.
  if value == 'accent' then
    return theme.colors.accentText
  end
  local found = (theme.colors :: any)[value]
  assert(type(found) == 'table', `ui: '{tostring(value)}' is not a colour role`)
  return found
end

function tokens.typography(theme: uiHost.Theme, role: string?): uiHost.Typography
  local found = (theme.type :: any)[role or 'body']
  assert(type(found) == 'table', `ui: '{tostring(role)}' is not a type role`)
  return found
end

export type TextOptions = {
  align: ('start' | 'center' | 'end')?,
  wrap: ('none' | 'word' | 'word-or-glyph')?,
  maxLines: number?,
}

function tokens.textStyle(theme: uiHost.Theme, role: string?, options: TextOptions?): lunette.LayoutTextStyle
  local style = tokens.typography(theme, role)
  local given: TextOptions = options or {}
  return {
    family = style.family,
    size = style.size,
    weight = style.weight,
    lineHeight = style.lineHeight,
    align = given.align,
    wrap = given.wrap,
    maxLines = given.maxLines,
  }
end

-- The flex container style that the layout props of Column, Row, and their relatives describe.
function tokens.container(theme: uiHost.Theme, props: uiHost.Props, direction: 'row' | 'column'): lunette.LayoutStyle
  return {
    flexDirection = direction,
    gap = tokens.space(theme, props.gap),
    padding = tokens.space(theme, props.padding),
    alignItems = props.align,
    justifyContent = props.justify,
    grow = props.grow,
    shrink = props.shrink,
    wrap = if props.wrap then 'wrap' else nil,
    width = props.width,
    height = props.height,
    minWidth = props.minWidth,
    maxWidth = props.maxWidth,
    minHeight = props.minHeight,
    maxHeight = props.maxHeight,
    alignSelf = props.alignSelf,
  }
end

-- A disabled control shows why it is disabled and takes no input.
function tokens.enabled(props: uiHost.Props): boolean
  return props.disabledReason == nil and props.disabled ~= true
end

return tokens
