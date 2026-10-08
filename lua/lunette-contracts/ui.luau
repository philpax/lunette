-- Owner-scoped VR panels share declared logical geometry for input, drawing, and inspection.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local owner = require '@lunette-contracts/owner'
local surface = require '@lunette-contracts/surface'
local focus = require '@lunette-contracts/focus'
local theme = require '@lunette-contracts/theme'

local ui = {}

export type Owner = owner.Owner
export type OwnerIdentity = { read kind: 'ui-owner' }
export type Bounds = { read x: number, read y: number, read width: number, read height: number }
export type Point = { read x: number, read y: number }
export type Kind = 'button' | 'text-field' | 'choice' | 'list' | 'region'
export type Color = { read [number]: number }
export type Theme = {
  read background: Color,
  read foreground: Color,
  read control: Color,
  read hovered: Color,
  read pressed: Color,
  read disabled: Color,
  read focus: Color,
  read selection: Color,
  read error: Color,
  read border: Color,
  read font: Font,
  read fontSize: number,
  read panelRadius: number,
  read controlRadius: number,
  read padding: number,
  read spacing: number,
  read borderWidth: number,
  read rowHeight: number,
  read hapticStrength: number,
  read hapticDuration: number,
}
export type ThemeOverrides = {
  read background: Color?,
  read foreground: Color?,
  read control: Color?,
  read hovered: Color?,
  read pressed: Color?,
  read disabled: Color?,
  read focus: Color?,
  read selection: Color?,
  read error: Color?,
  read border: Color?,
  read font: theme.FontSpec?,
  read fontSize: number?,
  read panelRadius: number?,
  read controlRadius: number?,
  read padding: number?,
  read spacing: number?,
  read borderWidth: number?,
  read rowHeight: number?,
  read hapticStrength: number?,
  read hapticDuration: number?,
}
export type Item = { read id: string, read label: string, read enabled: boolean? }
export type RegionItem = {
  read id: string,
  read label: string?,
  read bounds: Bounds,
  read route: { read [number]: Point }?,
}
export type ItemDescription = {
  read id: string,
  read label: string,
  read enabled: boolean,
  read selected: boolean,
  read bounds: Bounds?,
  read route: { read [number]: Point }?,
}
export type ControlDescription = {
  read id: string,
  read owner: OwnerIdentity,
  read kind: Kind,
  read label: string,
  read enabled: boolean,
  read bounds: Bounds?,
  read items: { read [number]: ItemDescription },
}
export type Generation = { read kind: 'ui-generation' }
export type Description = {
  read name: string,
  read generation: Generation,
  read revision: number,
  read pose: { read [number]: number },
  read width: number,
  read height: number,
  read logicalWidth: number,
  read logicalHeight: number,
  read visible: boolean,
  read controls: { read [number]: ControlDescription },
}
export type Visual = {
  read id: string,
  read kind: Kind | 'panel',
  read label: string,
  read bounds: Bounds,
  read clip: Bounds,
  read theme: Theme,
  read enabled: boolean,
  read hovered: boolean,
  read pressed: boolean,
  read focused: boolean,
  read value: string?,
  read caret: number?,
  read anchor: number?,
  read error: string?,
  read opened: boolean?,
  read overflow: boolean?,
  read items: { read [number]: ItemDescription },
}
-- Hooks receive logical panel coordinates and cannot change declared input geometry.
export type Renderer = (Pass, Visual) -> ()
export type DrawHook = (Pass, Visual, Renderer) -> ()
export type Options = {
  read id: string,
  read bounds: Bounds,
  read label: string?,
  read enabled: boolean?,
  read z: number?,
  read theme: ThemeOverrides?,
  read draw: DrawHook?,
  read exclusive: boolean?,
}
export type ButtonOptions = Options & { read onActivate: () -> () }
export type TextFieldOptions = Options & {
  read value: string?,
  read onChange: ((string) -> ())?,
  read onSubmit: ((string) -> ())?,
  read onCancel: ((string) -> ())?,
  read validate: ((string) -> string?)?,
  read keymapSeat: lunette.Seat?,
}
export type ChoiceOptions = Options & {
  read items: { read [number]: Item },
  read selected: string?,
  read onChange: (string) -> (),
}
export type ListOptions = Options & {
  read items: { read [number]: Item },
  read selected: string?,
  read onChange: ((string) -> ())?,
}
export type RegionOptions = Options & {
  read items: { read [number]: RegionItem }?,
  read onPointer: ((surface.PointerEvent) -> ())?,
  read receiver: focus.Receiver?,
  read wantsKeyboard: boolean?,
}
export type Control = {
  read dead: boolean,
  read id: string,
  read owner: OwnerIdentity,
  read setBounds: (Control, Bounds) -> (),
  read setEnabled: (Control, boolean) -> (),
  read setTheme: (Control, ThemeOverrides?) -> (),
  read destroy: (Control) -> boolean,
}
export type Button = Control
export type TextField = Control & {
  read setValue: (TextField, string) -> (),
  read value: (TextField) -> string,
  read setSelection: (TextField, number, number?) -> (),
  read selection: (TextField) -> (number, number),
  read setError: (TextField, string?) -> (),
  read focus: (TextField) -> boolean,
  read blur: (TextField) -> boolean,
}
export type Choice = Control & {
  read setItems: (Choice, { read [number]: Item }) -> (),
  read setSelected: (Choice, string?) -> (),
  read selected: (Choice) -> string?,
  read setOpen: (Choice, boolean) -> (),
  read scroll: (Choice, number) -> (),
}
export type List = Control & {
  read setItems: (List, { read [number]: Item }) -> (),
  read setSelected: (List, string?) -> (),
  read selected: (List) -> string?,
  read scroll: (List, number) -> (),
}
export type Region = Control & { read setItems: (Region, { read [number]: RegionItem }) -> () }
export type TitlebarStyle = {
  read font: Font,
  read cornerRadius: number,
  read barHeight: number,
  read margin: number,
  read barColor: Color,
  read barHighlightColor: Color,
  read borderThickness: number,
  read borderDepth: number,
  read borderColor: Color,
  read borderHighlightColor: Color,
  read titleHeight: number,
  read titleColor: Color,
}
export type TitlebarStyleOverrides = {
  read font: theme.FontSpec?,
  read cornerRadius: number?,
  read barHeight: number?,
  read margin: number?,
  read barColor: Color?,
  read barHighlightColor: Color?,
  read borderThickness: number?,
  read borderDepth: number?,
  read borderColor: Color?,
  read borderHighlightColor: Color?,
  read titleHeight: number?,
  read titleColor: Color?,
}
export type TitlebarAction = {
  read id: string,
  read label: string,
  -- Width in multiples of the bar height, limited to a share of the remaining panel width.
  read width: number?,
  read enabled: boolean?,
  read run: () -> (),
}
export type TitlebarOptions = {
  read title: string,
  read onClose: (() -> ())?,
  read closeId: string?,
  read actions: { read [number]: TitlebarAction }?,
  read style: TitlebarStyleOverrides?,
  read draggable: boolean?,
}
export type Titlebar = {
  read dead: boolean,
  read update: (Titlebar, TitlebarOptions) -> (),
  read sync: (Titlebar) -> (),
  read draw: (Titlebar, Pass) -> (),
  read destroy: (Titlebar) -> boolean,
}
export type PanelOptions = {
  read name: string,
  read pose: Mat4?,
  read width: number,
  read height: number,
  read logicalWidth: number,
  read logicalHeight: number,
  read visible: boolean?,
  read grabbable: boolean?,
  -- Grip moves this offered owning surface instead of the UI panel itself.
  read grabTarget: surface.Surface?,
  read theme: ThemeOverrides?,
  read draw: DrawHook?,
  read titlebar: TitlebarOptions?,
}
export type Panel = {
  read dead: boolean,
  read setPose: (Panel, Mat4) -> (),
  read setSize: (Panel, number, number, number?, number?) -> (),
  read setVisible: (Panel, boolean) -> (),
  read setTheme: (Panel, ThemeOverrides?) -> (),
  read setTitlebar: (Panel, TitlebarOptions?) -> (),
  read draw: (Panel, Pass) -> (),
  read describe: (Panel) -> Description,
  read destroy: (Panel) -> boolean,
  read button: (Panel, Owner, ButtonOptions) -> Button,
  read textField: (Panel, Owner, TextFieldOptions) -> TextField,
  read choice: (Panel, Owner, ChoiceOptions) -> Choice,
  read list: (Panel, Owner, ListOptions) -> List,
  read region: (Panel, Owner, RegionOptions) -> Region,
}
export type Service = {
  read newPanel: (Service, Owner, PanelOptions) -> Panel,
  read newTitlebar: (Service, Owner, string, surface.Surface, TitlebarOptions, (() -> boolean)?) -> Titlebar,
  read panels: (Service) -> { read [number]: Panel },
}
export type Capability = plugin.Capability<Service>
ui.capability = plugin.capability<<Service>> { name = 'lunette/ui', schema = 2 }

return ui
