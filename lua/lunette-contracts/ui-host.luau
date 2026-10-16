-- The UI toolkit host: panels, mount points, the element format, element kinds, visuals, and the drawing API.
-- Panel coordinates are metres from the panel's top-left corner, with x right and y down. Elevation is metres along
-- the panel's normal, towards the viewer.

local plugin = require '@lunette-plugin'
local lunette = require '@lunette'
local inspection = require '@lunette-contracts/inspection'
local vocabulary = require '@lunette-contracts/vocabulary'

local uiHost = {}

export type Owner = plugin.Owner
-- Colours are sRGB components from 0 to 1, with alpha.
export type Color = { read [number]: number }
export type Props = { read [string]: any }

-- A framework's own constructs never appear in a host element; it expands them into elements that name kinds.
export type Element = {
  read kind: string,
  read key: string?,
  read ref: Ref?,
  read props: Props,
  read children: { read [number]: Element },
  -- Each child's identity among its siblings: its key, or its position in the constructor's arguments. Positions
  -- count nil and false children, so a conditional child does not shift the identity of the children after it.
  -- A framework that builds elements by hand may omit it, and the host then keys unkeyed children by index.
  read slots: { read [number]: string }?,
}

-- The host's portal kind, 'lunette/portal', renders its children into an overlay panel raised above the portal's
-- parent, which it uses as the anchor. Its props are `placement` ('below' or 'above', flipping when the overlay does
-- not fit), `matchWidth` to take at least the anchor's width, `hit` (false for an overlay that takes no input),
-- `onDismiss`, which runs on a press outside the overlay and its opener, and `handoff`, which moves a ray press held
-- inside the parent onto the new overlay so the press can be released on an item there.

-- A child of an element constructor: nil and false hold their position, and arrays flatten in place.
export type Child = Element | { read [number]: Child } | false | nil

-- Receives the node handle when the node is created and nil when it is removed.
export type Ref = { current: Node? }

export type Rect = { read x: number, read y: number, read width: number, read height: number }

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
  read mode: 'dark' | 'light',
  read colors: Colors,
  read spacing: Spacing,
  read radii: Radii,
  read type: TypeScale,
  read elevation: Elevation,
  read sizes: Sizes,
  read motion: { read crisp: number },
}

-- What a kind, a visual, or a ref holder sees of a node.
export type Node = {
  read id: number,
  read kind: string,
  read key: string?,
  read props: Props,
  -- Host state (hovered, pressed, dragging) and the kind's declared state.
  read state: { read [string]: any },
  -- The node's box in its own coordinates, so x and y are zero.
  read bounds: Rect,
  read theme: Theme,
  read dead: boolean,
  read parent: Node?,
  -- Calls a prop callback under a protected call, reporting an error against the consumer.
  read emit: (Node, string, ...any) -> (),
  -- Merges fields into the kind's state and redraws or re-expands the node.
  read setState: (Node, { [string]: any } | ({ read [string]: any }) -> { [string]: any }) -> (),
  -- The node's box in panel coordinates.
  read panelBounds: (Node) -> Rect,
  -- The world pose of the centre of the node's surface, facing out of its panel.
  read pose: (Node) -> Mat4,
  -- Focuses the node, taking session focus for a text node, and answers whether the node is focusable.
  read focus: (Node) -> boolean,
  read blur: (Node) -> (),
  -- Animates a channel, such as 'opacity' or 'progress', to a target with the theme's motion. Visuals read channel
  -- values through `channel`.
  read animate: (Node, string, number) -> (),
  read channel: (Node, string) -> number,
  -- The live keyed descendant at a path such as 'face/label', searching through unkeyed nodes.
  read descendant: (Node, string) -> Node?,
  -- Shaped lines of a text node, in node coordinates.
  read textLines: (Node) -> { lunette.LayoutLine }?,
  -- The extent of the node's children from its origin, before scrolling.
  read contentSize: (Node) -> (number, number),
  -- Scrolls every scrolling ancestor by the least that brings the node into view. Focus moved by traversal does this.
  read scrollIntoView: (Node) -> (),
  -- Sets or moves the vertical offset of a node that scrolls, held within its content; a node that does not scroll
  -- raises.
  read scrollTo: (Node, number) -> (),
  read scrollBy: (Node, number) -> (),
}

export type BoxSpec = {
  read fill: Color?,
  read border: number?,
  read borderColor: Color?,
  read radius: number?,
  -- Metres above the node's surface for the box's top face.
  read offset: number?,
  -- Metres the box's sides extend below its top face; nil means down to the parent's surface.
  read depth: number?,
  -- Colour of the sides. A box without one is drawn as a flat face.
  read side: Color?,
  -- Draws the theme's light top edge and dark bottom edge on the face.
  read edges: boolean?,
  -- Radians about the box's centre in the panel plane, clockwise as drawn.
  read rotation: number?,
}

export type TextSpec = {
  read color: Color?,
  read offset: number?,
}

-- An image to draw: an SVG document, rasterised at the size it is drawn; an image file LÖVR can read; or a texture
-- the caller owns and keeps alive while it is drawn.
export type ImageSource =
  { read kind: 'svg', read data: string }
  | { read kind: 'file', read path: string }
  | { read kind: 'texture', read texture: Texture }

export type ImageSpec = {
  read source: ImageSource,
  -- Multiplies the image's colours, such as the ink colour for a monochrome icon.
  read tint: Color?,
  read offset: number?,
}

export type Draw = {
  -- A box in node coordinates; nil draws the node's bounds.
  read box: (Draw, Rect?, BoxSpec) -> (),
  -- The node's own shaped text, for a text kind.
  read text: (Draw, TextSpec) -> (),
  -- An image filling a box in node coordinates; nil draws over the node's bounds.
  read image: (Draw, Rect?, ImageSpec) -> (),
  -- A straight line with round ends between two points in node coordinates, such as a graph's edge.
  read line: (Draw, number, number, number, number, LineSpec) -> (),
}

export type LineSpec = {
  read width: number,
  read color: Color,
  read offset: number?,
}

export type Visual = (node: Node, draw: Draw, base: (Node, Draw) -> ()) -> ()

-- Positions are in the target node's coordinates.
export type Event =
  { read kind: 'hover-enter' }
  | { read kind: 'hover-leave' }
  -- Source tells a ray press from a fingertip, since an opener acts on a ray press but on a touch release.
  | { read kind: 'press', read x: number, read y: number, read source: ('ray' | 'touch')? }
  | { read kind: 'release', read x: number, read y: number, read inside: boolean }
  | { read kind: 'activate' }
  | { read kind: 'cancel', read reason: string }
  | { read kind: 'drag-start', read x: number, read y: number }
  | { read kind: 'drag', read x: number, read y: number, read dx: number, read dy: number }
  | { read kind: 'drag-end', read x: number, read y: number }
  -- A scroll carries the pointer's position in the receiving node, so a canvas can zoom about it.
  | { read kind: 'scroll', read dx: number, read dy: number, read x: number, read y: number }
  | { read kind: 'change', read key: string?, read value: any }
  -- Keys and committed text reach the panel's focused node and bubble to its ancestors. Source is 'controller' for
  -- traversal from a controller, which value controls handle only while engaged.
  | {
    read kind: 'key',
    read code: number,
    read modifiers: { read [number]: string },
    read isRepeat: boolean,
    read source: ('physical' | 'virtual' | 'controller')?,
  }
  | { read kind: 'text', read text: string }

export type EventHandler = (node: Node, event: Event, base: (Node, Event) -> ()) -> ()

-- Container kinds lay out their children with a style; text kinds are measured natively; leaf kinds take a size.
export type Layout =
  {
    read kind: 'container',
    read style: ((props: Props, theme: Theme, state: { read [string]: any }) -> lunette.LayoutStyle)?,
  }
  | {
    read kind: 'text',
    read text: (props: Props, theme: Theme) -> string,
    read style: ((props: Props, theme: Theme) -> lunette.LayoutStyle)?,
    read textStyle: (props: Props, theme: Theme) -> lunette.LayoutTextStyle,
  }
  -- A leaf sizes itself through its style's width, height, and aspect ratio.
  | { read kind: 'leaf', read style: ((props: Props, theme: Theme) -> lunette.LayoutStyle)? }

-- Actions are plain functions, so a composite's callbacks can close over them.
export type Actions = {
  read setState: ({ [string]: any } | ({ read [string]: any }) -> { [string]: any }) -> (),
  read emit: (string, ...any) -> (),
}

export type Role =
  'button'
  | 'checkbox'
  | 'switch'
  | 'radio'
  | 'radiogroup'
  | 'slider'
  | 'textbox'
  | 'combobox'
  | 'menu'
  | 'menuitem'
  | 'list'
  | 'listitem'
  | 'table'
  | 'row'
  | 'tab'
  | 'tablist'
  | 'link'
  | 'heading'
  | 'text'
  | 'image'
  | 'progressbar'
  | 'dialog'
  | 'alert'
  | 'group'
  | 'scrollbar'

export type Semantics = {
  read name: string?,
  read value: (string | number)?,
  read min: number?,
  read max: number?,
  read checked: boolean?,
  read selected: boolean?,
  read expanded: boolean?,
  read disabled: boolean?,
}

export type KindRegistration = {
  read name: string,
  read version: { read major: number, read minor: number }?,
  read layout: Layout?,
  read visuals: { read [number]: string }?,
  read event: EventHandler?,
  -- An elevation token name, or metres above the parent's surface.
  read elevation: (string | number | (props: Props, theme: Theme) -> number)?,
  -- The host lifts the node on hover and presses it in on press.
  read response: { read lift: boolean?, read travel: boolean? }?,
  -- 'text' takes session focus when pressed, so typing goes to the node; 'pointer' becomes the panel's focused node
  -- when pressed; 'none', the default, never takes focus.
  read focus: ('text' | 'pointer' | 'none')?,
  -- A value control that traversal engages before directions adjust its value.
  read engage: boolean?,
  -- Transitions when a node appears and when it is removed. An exiting node fades out at its last position.
  read motion: { read enter: ('fade' | 'none')?, read exit: ('fade' | 'none')? }?,
  -- An object schema for the kind's props. The host validates each element's props against it when they change and
  -- reports unknown or invalid props against the kind's owner; the node still renders with the props it was given.
  read props: { read parse: (unknown, string?) -> any }?,
  -- The node's role from the closed set, and its accessible name, value, range, and states.
  read role: Role?,
  read semantics: ((props: Props, state: { read [string]: any }) -> Semantics)?,
  -- Whether the node is a hit target, and the drags it claims.
  read interactive: ((props: Props) -> boolean)?,
  read claims: { read drag: ('x' | 'y' | 'both')? }?,
  -- Children are clipped to the node's bounds.
  read clip: boolean?,
  -- A trigger press on the node where no hit target lies grabs its panel, as a titlebar does. It applies to a panel
  -- that is grabbable.
  read handle: boolean?,
  read state: { read [string]: any }?,
  -- A composite kind expands into other elements instead of drawing. An override's expansion receives the
  -- expansion beneath it as `base`.
  read expand: Expand?,
}

export type Expand = (
  props: Props,
  children: { read [number]: Element },
  state: { read [string]: any },
  actions: Actions,
  base: Expand?
) -> Child

-- An element constructor takes one table: named fields are props, array entries are children.
export type Constructor = (props: { [any]: any }?) -> Element

export type Adapter = {
  read render: () -> (),
  read unmount: (() -> ())?,
}

export type Mount = {
  read bind: (Mount, Adapter) -> (),
  read schedule: (Mount) -> (),
  -- Reconciles the mount point's content against a whole element tree. Only valid inside `render`.
  read submit: (Mount, Element?) -> (),
  read committed: (Mount) -> boolean,
}

-- A kind's or an outlet's interface version. A minor version adds only optional fields, and a major version changes
-- or removes them.
export type Version = { read major: number, read minor: number }

-- The object schema of an outlet's props, from `@lunette-plugin/schema`.
export type OutletSchema = { read parse: (unknown, string?) -> any, read inspect: () -> any }

-- What an outlet's ordering function compares: the definition name of the plugin that contributed.
export type OutletEntry = { read contributor: string }

-- A named, typed point in a tree where other plugins contribute subtrees. `uiHost.outlet` declares one, and a tree
-- places it with the host's outlet kind, 'lunette/outlet', whose props are `outlet`, `props`, which the host
-- validates against the outlet's schema and passes to every contribution, and `maxHeight`, the metres each
-- contribution may take before it is clipped. Each placement is a separate instance, so every contribution renders
-- once for each placement, with separate state and effects. Contributions render in the outlet's order: its `order`
-- function, which answers whether the first entry goes before the second, or the contributors' names, so a reload
-- does not move them. An attributed outlet draws each contribution in a host-drawn frame that names the contributing
-- plugin and clips the contribution.
export type Outlet<S> = {
  read name: string,
  read version: Version,
  read props: S,
  read attributed: boolean,
  read order: ((OutletEntry, OutletEntry) -> boolean)?,
}

export type OutletSpec<S> = {
  read name: string,
  read version: Version,
  read props: S,
  read attributed: boolean?,
  read order: ((OutletEntry, OutletEntry) -> boolean)?,
}

-- One placement's mount point for a contribution: a mount point whose props are the placement's. The host schedules
-- it when the placement's props change.
export type OutletMount = Mount & { read props: (Mount) -> Props }

export type Contribution = {
  -- The outlet version the contribution is built against: the contributed outlet's version when omitted. The host
  -- accepts it at a placement of the same major version and an equal or higher minor version.
  read version: Version?,
  -- Binds the mount point of one placement of the outlet. The host calls it once for each placement, and calls the
  -- adapter's `unmount` when the placement or the contribution ends.
  read bind: (OutletMount) -> (),
}

export type PanelOptions = {
  read name: string,
  -- Fixed sizes in metres; a content-sized panel takes its content's size, up to these when given.
  read width: number?,
  read height: number?,
  read size: ('fixed' | 'content')?,
  read pose: Mat4?,
  read grabbable: boolean?,
  -- A panel created hidden shows when setVisible is called.
  read visible: boolean?,
  -- 'world' stays where it is put; 'follow' lazily follows the head, as toasts do; 'dialog' floats in front of its
  -- parent panel, or in front of the head without one, and is modal.
  read presentation: ('world' | 'follow' | 'dialog' | 'attach')?,
  -- Bends the panel as a vertical cylinder of radius 1 / curve, centred on the viewer's side; zero is flat.
  read curve: number?,
  -- An attached panel sits above the top edge of a surface, such as a window panel, is at least as wide as it,
  -- growing to fit content that needs more, and moves it when grabbed; `gap` is metres between the two.
  read target: vocabulary.Surface?,
  read gap: number?,
  read parent: Panel?,
  -- A dialog blocks presses on its parent panel, or on every other toolkit panel when it is session-modal.
  read modality: ('panel' | 'session')?,
}

export type Panel = {
  read name: string,
  read dead: boolean,
  read root: Mount,
  read pose: (Panel) -> Mat4,
  read setPose: (Panel, Mat4) -> (),
  read size: (Panel) -> (number, number),
  read setVisible: (Panel, boolean) -> (),
  read setCurve: (Panel, number) -> (),
  -- Sets a fixed panel's size, or a content-sized panel's maximum, in metres.
  read setSize: (Panel, number?, number?) -> (),
  -- Whether the grip and a header's trigger drag move a world or attached panel.
  read setGrabbable: (Panel, boolean) -> (),
  -- Sets the gap above an attached panel's target.
  read setGap: (Panel, number) -> (),
  read destroy: (Panel) -> (),
  -- The live node with this key path, such as 'controls/enabled', for tests and inspection.
  read find: (Panel, string) -> Node?,
}

export type FontRegistration = {
  read family: string,
  read weight: number?,
  -- A path that `lovr.filesystem` reads, such as an alias path.
  read file: string,
}

export type Service = {
  read newPanel: (Service, Owner, PanelOptions) -> Panel,
  read registerKind: (Service, Owner, KindRegistration) -> Constructor,
  read registerVisual: (Service, Owner, string, Visual) -> plugin.Effect,
  read registerFont: (Service, Owner, FontRegistration) -> plugin.Effect,
  -- Replaces a registered kind under its name for the owner's lifetime. The newest live override is current, fields
  -- it omits keep the previous registration's, and its `event` and `expand` reach the previous ones as `base`. Nodes
  -- of the kind are made again when the current registration changes.
  read overrideKind: (Service, Owner, string, KindRegistration) -> plugin.Effect,
  -- Contributes to an outlet for the owner's lifetime. It raises when the contribution's version is incompatible with
  -- the outlet's, or when another live declaration of the outlet's name and version has a different schema. Errors
  -- the contribution raises are reported against its owner and leave the rest of the tree rendering.
  read contribute: (Service, Owner, Outlet<any>, Contribution) -> plugin.Effect,
  -- Default appearance renders every panel with the base registration of every kind, the base visual of every
  -- visual name, and the base theme, while the accessibility settings still apply. A held chord of both thumbstick
  -- clicks toggles it as well.
  read setDefaultAppearance: (Service, boolean) -> (),
  read defaultAppearance: (Service) -> boolean,
  read theme: (Service) -> Theme,
  read setMode: (Service, 'dark' | 'light') -> (),
  read setAccent: (Service, Color) -> (),
  -- The accessibility settings the host applies: text scale and high contrast reach the theme, reduced motion snaps
  -- hover lift and press travel, and haptics off silences press feedback.
  read setAccessibility: (Service, AccessibilityOptions) -> (),
  -- Traversal of the panel that holds session focus, for bindings and switch access: a direction, activation,
  -- dismissal, and moving session focus to the next panel. Each answers whether it did anything.
  read navigate: (Service, 'up' | 'down' | 'left' | 'right' | 'next' | 'previous') -> boolean,
  read activate: (Service) -> boolean,
  read dismiss: (Service) -> boolean,
  read nextPanel: (Service) -> boolean,
  -- Panels and their sizes, as the plugin manager and other brokers' inspection show them.
  read inspect: (Service) -> inspection.Snapshot,
  -- Every node with a role, with its id, semantics, box, and states, for tests and assistive plugins. It is separate
  -- from inspect, because a panel that shows inspection would otherwise show its own growing node list.
  read inspectNodes: (Service) -> inspection.Snapshot,
  -- The live node with an id of a panel's name and a key path, such as 'Widget gallery:pages/display', for tests and
  -- inspection.
  read find: (Service, string) -> Node?,
  -- The first live node with a role and an accessible name, searching every panel, as a user who sees the panel
  -- would describe it.
  read findByRole: (Service, Role, string) -> Node?,
}

export type AccessibilityOptions = {
  read textScale: number?,
  read highContrast: boolean?,
  read reducedMotion: boolean?,
  read haptics: boolean?,
}

export type Capability = plugin.Capability<Service>

uiHost.capability = plugin.capability<<Service>> { name = 'lunette/ui-host', version = 1 }

local function highest(list: { [any]: any }): number
  local count = 0
  for index in list do
    if type(index) == 'number' and index > count then
      count = index
    end
  end
  return count
end

-- Positional slots start with '#', which a key cannot contain, so a slot never collides with a key.
local function flatten(child: any, into: { Element }, slots: { string }, position: string): ()
  if child == nil or child == false then
    return
  end
  assert(type(child) == 'table', 'ui: a child is an element, an array of elements, nil, or false')
  if child.kind ~= nil then
    into[#into + 1] = child
    slots[#slots + 1] = child.key or position
    return
  end
  for index = 1, highest(child) do
    flatten(child[index], into, slots, position .. ':' .. index)
  end
end

-- Builds an element for a kind. Array entries of `props` are children; `key` and `ref` are taken out of the props.
function uiHost.element(kind: string, props: { [any]: any }?): Element
  local fields: { [string]: any } = {}
  local children: { Element } = {}
  local slots: { string } = {}
  local key: string? = nil
  local ref: Ref? = nil
  if props then
    for name, value in props do
      if name == 'key' then
        key = tostring(value)
      elseif name == 'ref' then
        ref = value
      elseif type(name) == 'string' then
        fields[name] = value
      end
    end
    for index = 1, highest(props) do
      flatten(props[index], children, slots, '#' .. index)
    end
  end
  if key then
    assert(not string.find(key, '[/:@#]'), `ui: the key '{key}' contains a separator character`)
  end
  return table.freeze {
    kind = kind,
    key = key,
    ref = ref,
    props = table.freeze(fields),
    children = table.freeze(children),
    slots = table.freeze(slots),
  }
end

local OUTLET_FIELDS: { [string]: boolean } =
  { name = true, version = true, props = true, attributed = true, order = true }

local function wholeNumber(value: unknown): boolean
  return type(value) == 'number' and value >= 0 and value == math.floor(value) and value < math.huge
end

-- Declares an outlet. It is a pure function, so a contract module can declare its outlets and be required twice.
function uiHost.outlet<S>(spec: OutletSpec<S>): Outlet<S>
  assert(type(spec) == 'table', 'ui: an outlet declaration is a table')
  for field in spec :: any do
    assert(OUTLET_FIELDS[field], `ui: '{tostring(field)}' is not an outlet field`)
  end
  local name = spec.name
  assert(type(name) == 'string' and name ~= '', 'ui: an outlet has a name')
  local version = spec.version
  assert(
    type(version) == 'table' and wholeNumber(version.major) and wholeNumber(version.minor),
    `ui: the outlet {name} has a version of whole major and minor numbers`
  )
  local props = spec.props :: any
  assert(
    type(props) == 'table' and type(props.parse) == 'function' and type(props.inspect) == 'function',
    `ui: the outlet {name} has a props schema`
  )
  local attributed = spec.attributed
  assert(attributed == nil or type(attributed) == 'boolean', `ui: the outlet {name} is attributed or not`)
  local order = spec.order
  assert(order == nil or type(order) == 'function', `ui: the outlet {name} orders with a function`)
  return table.freeze {
    name = name,
    version = table.freeze { major = version.major, minor = version.minor },
    props = spec.props,
    attributed = attributed == true,
    order = order,
  }
end

-- A key for an arbitrary identifier, such as a plugin id: the separator characters and '%' are percent-encoded,
-- so distinct identifiers give distinct keys.
function uiHost.keyOf(identifier: string): string
  return (
    string.gsub(identifier, '[%%/:@#]', function(character: string): string
      return string.format('%%%02X', string.byte(character))
    end)
  )
end

-- Flattens constructor children into a list of elements and their slots.
function uiHost.children(child: Child): ({ Element }, { string })
  local list: { Element } = {}
  local slots: { string } = {}
  flatten(child, list, slots, '#')
  return list, slots
end

return uiHost
