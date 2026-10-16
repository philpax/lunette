-- The UI toolkit host: panels, mount points, the element format, element kinds, visuals, and the drawing API.
-- Panel coordinates are metres from the panel's top-left corner, with x right and y down. Elevation is metres along
-- the panel's normal, towards the viewer.

local plugin = require '@lunette-plugin'
local lunette = require '@lunette'
local inspection = require '@lunette-contracts/inspection'

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
  read danger: Color,
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
  -- Shaped lines of a text node, in node coordinates.
  read textLines: (Node) -> { lunette.LayoutLine }?,
  -- The extent of the node's children from its origin, before scrolling.
  read contentSize: (Node) -> (number, number),
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
}

export type TextSpec = {
  read color: Color?,
  read offset: number?,
}

export type Draw = {
  -- A box in node coordinates; nil draws the node's bounds.
  read box: (Draw, Rect?, BoxSpec) -> (),
  -- The node's own shaped text, for a text kind.
  read text: (Draw, TextSpec) -> (),
}

export type Visual = (node: Node, draw: Draw, base: (Node, Draw) -> ()) -> ()

-- Positions are in the target node's coordinates.
export type Event =
  { read kind: 'hover-enter' }
  | { read kind: 'hover-leave' }
  | { read kind: 'press', read x: number, read y: number }
  | { read kind: 'release', read x: number, read y: number, read inside: boolean }
  | { read kind: 'activate' }
  | { read kind: 'cancel', read reason: string }
  | { read kind: 'drag-start', read x: number, read y: number }
  | { read kind: 'drag', read x: number, read y: number, read dx: number, read dy: number }
  | { read kind: 'drag-end', read x: number, read y: number }
  | { read kind: 'scroll', read dx: number, read dy: number }
  | { read kind: 'change', read key: string?, read value: any }

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
  -- Whether the node is a hit target, and the drags it claims.
  read interactive: ((props: Props) -> boolean)?,
  read claims: { read drag: ('x' | 'y' | 'both')? }?,
  -- Children are clipped to the node's bounds.
  read clip: boolean?,
  read state: { read [string]: any }?,
  -- A composite kind expands into other elements instead of drawing.
  read expand: ((
    props: Props,
    children: { read [number]: Element },
    state: { read [string]: any },
    actions: Actions
  ) -> { Child })?,
}

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

export type PanelOptions = {
  read name: string,
  -- Fixed sizes in metres; a content-sized panel takes its content's size, up to these when given.
  read width: number?,
  read height: number?,
  read size: ('fixed' | 'content')?,
  read pose: Mat4?,
  read grabbable: boolean?,
}

export type Panel = {
  read name: string,
  read dead: boolean,
  read root: Mount,
  read pose: (Panel) -> Mat4,
  read setPose: (Panel, Mat4) -> (),
  read size: (Panel) -> (number, number),
  read setVisible: (Panel, boolean) -> (),
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
  read theme: (Service) -> Theme,
  read setMode: (Service, 'dark' | 'light') -> (),
  read setAccent: (Service, Color) -> (),
  read inspect: (Service) -> inspection.Snapshot,
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

-- Flattens constructor children into a list of elements and their slots.
function uiHost.children(child: Child): ({ Element }, { string })
  local list: { Element } = {}
  local slots: { string } = {}
  flatten(child, list, slots, '#')
  return list, slots
end

return uiHost
