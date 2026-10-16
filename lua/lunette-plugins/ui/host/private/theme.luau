-- Resolves the default lunette theme for a mode and an accent colour.

local uiHost = require '@lunette-contracts/ui-host'

local theme = {}

export type Mode = 'dark' | 'light'

local PALETTES: { [Mode]: { [string]: string } } = {
  dark = {
    surface = '#161c29',
    raised = '#1e2638',
    sunken = '#111622',
    side = '#0c111b',
    ink = '#e2e8f2',
    muted = '#94a0b6',
    line = '#2c364c',
    band = '#212a3c',
    bandInk = '#e8edf5',
    section = '#212a3c',
    sectionInk = '#e8edf5',
    danger = '#f08080',
    success = '#8fd6a0',
    warning = '#e8c27a',
  },
  light = {
    surface = '#c9cfd9',
    raised = '#e0e4eb',
    sunken = '#b9c0cc',
    side = '#98a1b0',
    ink = '#232c40',
    muted = '#4b566a',
    line = '#a0a9b8',
    band = '#46526b',
    bandInk = '#f4f7fb',
    section = '#5a6680',
    sectionInk = '#f4f7fb',
    danger = '#a8323a',
    success = '#2f7a45',
    warning = '#8a6216',
  },
}

theme.DEFAULT_ACCENT = table.freeze { 0x9f / 255, 0xd3 / 255, 0xe6 / 255, 1 }

-- Contrast ratios from WCAG 2: the accent against the surface, and ink against the accent.
local ACCENT_CONTRAST = 3
local INK_CONTRAST = 4.5

function theme.hex(value: string): uiHost.Color
  assert(string.match(value, '^#%x%x%x%x%x%x$'), `ui theme: '{value}' is not a #rrggbb colour`)
  return table.freeze {
    tonumber(string.sub(value, 2, 3), 16) :: number / 255,
    tonumber(string.sub(value, 4, 5), 16) :: number / 255,
    tonumber(string.sub(value, 6, 7), 16) :: number / 255,
    1,
  }
end

local function channel(value: number): number
  if value <= 0.04045 then
    return value / 12.92
  end
  return ((value + 0.055) / 1.055) ^ 2.4
end

function theme.luminance(color: uiHost.Color): number
  return 0.2126 * channel(color[1]) + 0.7152 * channel(color[2]) + 0.0722 * channel(color[3])
end

function theme.contrast(first: uiHost.Color, second: uiHost.Color): number
  local a, b = theme.luminance(first), theme.luminance(second)
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05)
end

function theme.mix(from: uiHost.Color, to: uiHost.Color, amount: number): uiHost.Color
  return table.freeze {
    from[1] + (to[1] - from[1]) * amount,
    from[2] + (to[2] - from[2]) * amount,
    from[3] + (to[3] - from[3]) * amount,
    (from[4] or 1) + ((to[4] or 1) - (from[4] or 1)) * amount,
  }
end

local WHITE = table.freeze { 1, 1, 1, 1 }
local BLACK = table.freeze { 0, 0, 0, 1 }

-- Moves the accent away from the surface's lightness until it reaches the contrast guard.
function theme.guardAccent(accent: uiHost.Color, surface: uiHost.Color, required: number?): uiHost.Color
  local target = if theme.luminance(surface) < 0.18 then WHITE else BLACK
  local guarded = accent
  for step = 1, 20 do
    if theme.contrast(guarded, surface) >= (required or ACCENT_CONTRAST) then
      break
    end
    guarded = theme.mix(accent, target, step / 20)
  end
  return guarded
end

-- The darker or lighter of the palette's inks, whichever reads on the accent, falling back to black or white.
function theme.inkOn(fill: uiHost.Color, dark: uiHost.Color, light: uiHost.Color): uiHost.Color
  for _, candidate in { dark, light, BLACK, WHITE } do
    if theme.contrast(candidate, fill) >= INK_CONTRAST then
      return candidate
    end
  end
  return if theme.luminance(fill) > 0.18 then BLACK else WHITE
end

local SPACING: uiHost.Spacing = table.freeze { xs = 0.002, sm = 0.004, md = 0.008, lg = 0.012, xl = 0.018 }
local RADII: uiHost.Radii = table.freeze { panel = 0.003, control = 0.0015, pill = 0.5 }
local ELEVATION: uiHost.Elevation = table.freeze {
  base = 0,
  raised = 0.003,
  selected = 0.0045,
  thumb = 0.005,
  popover = 0.006,
  dialog = 0.048,
  hoverLift = 0.001,
  pressTravel = 0.0025,
  minimumSeparation = 0.0005,
  contentOffset = 0.00025,
  panelDepth = 0.004,
}
local SIZES: uiHost.Sizes = table.freeze {
  control = 0.03,
  row = 0.034,
  header = 0.042,
  section = 0.026,
  toggleWidth = 0.04,
  toggleHeight = 0.022,
  check = 0.018,
  rail = 0.004,
  thumb = 0.018,
  rule = 0.0006,
  headerRule = 0.0012,
  underline = 0.0012,
  scrollbar = 0.003,
  edge = 0.0004,
}
local MOTION = table.freeze { crisp = 0.12 }

local function typography(
  family: string,
  size: number,
  weight: number,
  lineHeight: number,
  letterSpacing: number?
): uiHost.Typography
  return table.freeze {
    family = family,
    size = size,
    weight = weight,
    lineHeight = lineHeight,
    letterSpacing = letterSpacing,
  }
end

local SANS = 'IBM Plex Sans'
local MONO = 'Iosevka'
local TYPE: uiHost.TypeScale = table.freeze {
  body = typography(SANS, 0.012, 400, 1.35),
  label = typography(SANS, 0.012, 500, 1.3),
  caption = typography(SANS, 0.0095, 400, 1.3),
  section = typography(SANS, 0.0095, 600, 1.3, 0.1),
  heading = typography(SANS, 0.014, 600, 1.3),
  title = typography(SANS, 0.017, 600, 1.25),
  value = typography(MONO, 0.013, 400, 1.3),
  mono = typography(MONO, 0.011, 400, 1.35),
  readout = typography(MONO, 0.0095, 400, 1.3),
  engraved = typography(MONO, 0.0085, 400, 1.3, 0.12),
}

export type Options = {
  -- Multiplies every typography role's size.
  read textScale: number?,
  -- Pushes ink, lines, and edges to the extremes of the mode.
  read highContrast: boolean?,
}

local HIGH_CONTRAST: { [Mode]: { [string]: string } } = {
  dark = {
    surface = '#0b0e15',
    raised = '#161c29',
    sunken = '#05070b',
    side = '#000000',
    ink = '#ffffff',
    muted = '#d4dae4',
    line = '#8a95aa',
    band = '#1b2333',
    bandInk = '#ffffff',
    section = '#1b2333',
    sectionInk = '#ffffff',
    danger = '#ffb3ab',
  },
  light = {
    surface = '#e6e9ee',
    raised = '#ffffff',
    sunken = '#d0d5dd',
    side = '#7c8596',
    ink = '#000000',
    muted = '#2a3346',
    line = '#4f596d',
    band = '#26304a',
    bandInk = '#ffffff',
    section = '#26304a',
    sectionInk = '#ffffff',
    danger = '#7d1414',
  },
}

local function scaled(scale: number): uiHost.TypeScale
  if scale == 1 then
    return TYPE
  end
  local result: { [string]: uiHost.Typography } = {}
  for name, role in TYPE :: any do
    result[name] = typography(role.family, role.size * scale, role.weight, role.lineHeight, role.letterSpacing)
  end
  return table.freeze(result) :: any
end

function theme.resolve(mode: Mode, accent: uiHost.Color, options: Options?): uiHost.Theme
  local given: Options = options or {}
  local base = assert(PALETTES[mode], `ui theme: '{mode}' is not a mode`)
  local palette = base
  if given.highContrast then
    palette = table.clone(base)
    for name, value in HIGH_CONTRAST[mode] do
      palette[name] = value
    end
  end
  local function named(name: string): uiHost.Color
    return theme.hex(assert(palette[name], `ui theme: the palette has no {name}`))
  end
  local surface, raised, sunken, ink, band = named 'surface', named 'raised', named 'sunken', named 'ink', named 'band'
  local bandInk = named 'bandInk'
  local guarded = theme.guardAccent(accent, surface)
  local header = theme.mix(band, guarded, if mode == 'dark' then 0.2 else 0.22)
  local colors: uiHost.Colors = table.freeze {
    surface = surface,
    raised = raised,
    sunken = sunken,
    side = named 'side',
    ink = ink,
    muted = named 'muted',
    line = named 'line',
    band = band,
    bandInk = bandInk,
    header = header,
    headerRule = theme.mix(band, guarded, 0.55),
    headerMuted = theme.mix(header, bandInk, if given.highContrast then 0.95 else 0.8),
    section = theme.mix(named 'section', guarded, if mode == 'dark' then 0.09 else 0.1),
    sectionInk = named 'sectionInk',
    accent = guarded,
    accentInk = theme.inkOn(guarded, sunken, raised),
    accentText = theme.guardAccent(guarded, surface, INK_CONTRAST),
    danger = named 'danger',
    dangerInk = theme.inkOn(named 'danger', sunken, raised),
    success = named 'success',
    warning = named 'warning',
    hover = theme.mix(raised, ink, 0.06),
    pressed = theme.mix(raised, ink, 0.12),
    rail = sunken,
    edgeLight = if mode == 'dark' then table.freeze { 1, 1, 1, 0.07 } else table.freeze { 1, 1, 1, 0.5 },
    edgeDark = if mode == 'dark' then table.freeze { 0, 0, 0, 0.35 } else table.freeze { 0, 0, 0, 0.18 },
  }
  return table.freeze {
    mode = mode,
    colors = colors,
    spacing = SPACING,
    radii = RADII,
    type = scaled(given.textScale or 1),
    elevation = ELEVATION,
    sizes = SIZES,
    motion = MOTION,
  }
end

-- A token name resolves through its table; a number is taken as metres.
function theme.length(tokens: any, value: (string | number)?, fallback: number): number
  if value == nil then
    return fallback
  end
  if type(value) == 'number' then
    return value
  end
  local found = (tokens :: { [string]: number? })[value]
  return assert(found, `ui theme: '{value}' is not a token`)
end

return theme
