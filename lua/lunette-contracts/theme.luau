-- Runtime themes carry immutable style data; the provider caches one face per font specification.

local plugin = require '@lunette-plugin'
local inspection = require '@lunette-contracts/inspection'

local theme = {}

export type Owner = plugin.Owner
export type Color = { read [number]: number }
export type DefaultFontSpec = { read kind: 'default' }
export type FileFontSpec = {
  read kind: 'file',
  read file: string,
  read size: number,
  read spread: number,
}
export type FontSpec = DefaultFontSpec | FileFontSpec

export type Colors = {
  read background: Color,
  read elevatedBackground: Color,
  read foreground: Color,
  read mutedForeground: Color,
  read control: Color,
  read hovered: Color,
  read pressed: Color,
  read disabled: Color,
  read border: Color,
  read focus: Color,
  read selection: Color,
  read error: Color,
  read errorBackground: Color,
  read success: Color,
  read warning: Color,
  read ownershipEdge: Color,
  read dependencyEdge: Color,
  read pointer: Color,
  read pointerHovered: Color,
}
export type Typography = {
  read font: FontSpec,
  read bodySize: number,
  read smallSize: number,
  read titleHeight: number,
  read keyboardLegendHeight: number,
  read errorTextHeight: number,
  read hintTextHeight: number,
}
export type Metrics = {
  read padding: number,
  read spacing: number,
  read borderWidth: number,
  read rowHeight: number,
  read titlebarHeight: number,
  read titlebarBorderThickness: number,
  read keyboardGap: number,
}
export type Radii = {
  read uiPanel: number,
  read uiControl: number,
  read keyboardBacking: number,
  read keyboardKey: number,
  read titlebar: number,
  read window: number,
  read monitor: number,
}
export type Theme = {
  read colors: Colors,
  read typography: Typography,
  read metrics: Metrics,
  read radii: Radii,
}

export type ColorOverrides = {
  read background: Color?,
  read elevatedBackground: Color?,
  read foreground: Color?,
  read mutedForeground: Color?,
  read control: Color?,
  read hovered: Color?,
  read pressed: Color?,
  read disabled: Color?,
  read border: Color?,
  read focus: Color?,
  read selection: Color?,
  read error: Color?,
  read errorBackground: Color?,
  read success: Color?,
  read warning: Color?,
  read ownershipEdge: Color?,
  read dependencyEdge: Color?,
  read pointer: Color?,
  read pointerHovered: Color?,
}
export type TypographyOverrides = {
  read font: FontSpec?,
  read bodySize: number?,
  read smallSize: number?,
  read titleHeight: number?,
  read keyboardLegendHeight: number?,
  read errorTextHeight: number?,
  read hintTextHeight: number?,
}
export type MetricOverrides = {
  read padding: number?,
  read spacing: number?,
  read borderWidth: number?,
  read rowHeight: number?,
  read titlebarHeight: number?,
  read titlebarBorderThickness: number?,
  read keyboardGap: number?,
}
export type RadiusOverrides = {
  read uiPanel: number?,
  read uiControl: number?,
  read keyboardBacking: number?,
  read keyboardKey: number?,
  read titlebar: number?,
  read window: number?,
  read monitor: number?,
}
export type ThemeOverrides = {
  read colors: ColorOverrides?,
  read typography: TypographyOverrides?,
  read metrics: MetricOverrides?,
  read radii: RadiusOverrides?,
}

export type Snapshot = {
  read revision: number,
  read theme: Theme,
}
export type Registration = {
  read update: (Registration, ThemeOverrides) -> (),
  read dispose: (Registration) -> (),
}
export type Listener = { read run: (Snapshot) -> () }
export type Service = {
  read current: (Service) -> Snapshot,
  -- Returns the face for a specification, or for the current theme's when it is omitted.
  read font: (Service, FontSpec?) -> Font,
  read select: (Service, Owner, ThemeOverrides) -> Registration,
  read onChanged: (Service, Owner, Listener) -> plugin.Effect,
  read inspect: (Service) -> inspection.Snapshot,
}
export type Capability = plugin.Capability<Service>

theme.capability = plugin.capability<<Service>> { name = 'lunette/theme', version = 1 }

return theme
