-- The session's theme: the resolved tokens that the UI toolkit lays out and draws with, which surfaces drawn outside
-- the toolkit, such as the virtual keyboard, the laser, the mouse cursor, and window outlines, also take their
-- colours from. The theme provider sits below the UI host, so those surfaces keep their appearance while the host is
-- disabled or broken.

local plugin = require '@lunette-plugin'

local theme = {}

export type Owner = plugin.Owner
-- Colours are sRGB components from 0 to 1, with alpha.
export type Color = { read [number]: number }
export type Mode = 'dark' | 'light'

export type Typography = {
  read family: string,
  read size: number,
  read weight: number,
  read lineHeight: number,
  -- Extra space after each glyph, as a multiple of the size; nil sets text as the font spaces it.
  read letterSpacing: number?,
}

export type Colors = {
  read surface: Color,
  read raised: Color,
  read sunken: Color,
  read side: Color,
  read ink: Color,
  read muted: Color,
  read line: Color,
  read band: Color,
  read bandInk: Color,
  -- A panel header: the band tinted with the accent, its rule, and secondary text on it.
  read header: Color,
  read headerRule: Color,
  read headerMuted: Color,
  -- A section header band and its ink.
  read section: Color,
  read sectionInk: Color,
  read accent: Color,
  read accentInk: Color,
  -- The accent for text on the surface, guarded to the contrast text needs rather than that of marks.
  read accentText: Color,
  read danger: Color,
  -- Ink on a danger fill, such as a destructive action's button.
  read dangerInk: Color,
  read success: Color,
  read warning: Color,
  read hover: Color,
  read pressed: Color,
  read rail: Color,
  read edgeLight: Color,
  read edgeDark: Color,
}

export type Spacing = { read xs: number, read sm: number, read md: number, read lg: number, read xl: number }

export type Radii = { read panel: number, read control: number, read pill: number }

-- Metres along the panel normal.
export type Elevation = {
  read base: number,
  read raised: number,
  read selected: number,
  read thumb: number,
  read popover: number,
  read dialog: number,
  read hoverLift: number,
  read pressTravel: number,
  read minimumSeparation: number,
  read contentOffset: number,
  read panelDepth: number,
}

export type Sizes = {
  read control: number,
  read row: number,
  read header: number,
  read section: number,
  read toggleWidth: number,
  read toggleHeight: number,
  read check: number,
  read rail: number,
  read thumb: number,
  read rule: number,
  read headerRule: number,
  read underline: number,
  read scrollbar: number,
  read edge: number,
}

export type TypeScale = {
  read body: Typography,
  read label: Typography,
  read caption: Typography,
  read section: Typography,
  read heading: Typography,
  read title: Typography,
  read value: Typography,
  read mono: Typography,
  -- Small monospace text for readouts beside values: units, identifiers, and details.
  read readout: Typography,
  -- Small spaced monospace capitals engraved beside a control, such as a slider's detent names.
  read engraved: Typography,
}

-- The resolved tokens a kind lays out and draws with. Lengths are metres.
export type Theme = {
  read mode: Mode,
  read colors: Colors,
  read spacing: Spacing,
  read radii: Radii,
  read type: TypeScale,
  read elevation: Elevation,
  read sizes: Sizes,
  read motion: { read crisp: number },
}

-- The accessibility settings that change the theme.
export type Options = {
  -- Multiplies every typography role's size.
  read textScale: number?,
  -- Pushes ink, lines, and edges to the extremes of the mode.
  read highContrast: boolean?,
}

export type Service = {
  -- The theme for the current mode, accent, and options. A change resolves a new table, so a consumer that compares
  -- the theme it applied with the current one sees each change.
  read current: (Service) -> Theme,
  -- The base theme: the dark mode and the default accent, with the current options, which default appearance uses.
  read base: (Service) -> Theme,
  read setMode: (Service, Mode) -> (),
  -- Sets the accent colour; the theme guards its contrast against the surface rather than rejecting it.
  read setAccent: (Service, Color) -> (),
  read setOptions: (Service, Options) -> (),
  -- Calls `run` with the current theme after each change, for the owner's lifetime.
  read onChanged: (Service, Owner, { read run: (Theme) -> () }) -> plugin.Effect,
}

export type Capability = plugin.Capability<Service>

theme.capability = plugin.capability<<Service>> { name = 'lunette/theme', version = 2 }

return theme
