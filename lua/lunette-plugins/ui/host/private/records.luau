-- The host's private records for kinds, nodes, and panels.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'
local vocabulary = require '@lunette-contracts/vocabulary'

export type Kind = {
  name: string,
  owner: plugin.Owner,
  registration: uiHost.KindRegistration,
  composite: boolean,
  -- The host's portal kind renders its children into an overlay panel instead of its own.
  portal: boolean,
}

-- A drawn primitive in node coordinates, recorded by a visual and replayed every frame.
export type Primitive =
  {
    kind: 'box',
    x: number,
    y: number,
    width: number,
    height: number,
    offset: number,
    depth: number?,
    radius: number,
    border: number,
    fill: uiHost.Color,
    borderColor: uiHost.Color,
    side: uiHost.Color?,
    edges: boolean,
    rotation: number,
  }
  | {
    kind: 'text',
    lines: { lunette.LayoutLine },
    source: string,
    family: string,
    weight: number,
    x: number,
    y: number,
    color: uiHost.Color,
    offset: number,
  }
  | {
    kind: 'image',
    x: number,
    y: number,
    width: number,
    height: number,
    source: uiHost.ImageSource,
    tint: uiHost.Color,
    offset: number,
  }

export type Node = {
  id: number,
  kind: Kind,
  key: string?,
  slot: string,
  element: uiHost.Element,
  props: uiHost.Props,
  -- The kind's declared state.
  state: { [string]: any },
  -- Hover, press, and drag state, which the host owns.
  -- `hovers` counts the pointers hovering the node; one pointer at a time captures it.
  host: {
    hovers: number,
    pressed: boolean,
    dragging: boolean,
    focused: boolean,
    focusVisible: boolean,
    engaged: boolean,
  },
  parent: Node?,
  children: { Node },
  panel: Panel,
  -- The last style and text sent to the native tree, to skip unchanged updates.
  style: any,
  text: string?,
  textStyle: any,
  -- The native layout's placement in panel coordinates, before scrolling.
  u: number,
  v: number,
  -- Placement in panel coordinates for this frame, after scrolling.
  x: number,
  y: number,
  width: number,
  height: number,
  -- Metres above the parent's surface, from the kind, and the animated hover and press offset.
  elevation: number,
  lift: number,
  liftTarget: number,
  -- The surface height of the node in panel coordinates: its parent's surface plus elevation and lift.
  z: number,
  primitives: { Primitive }?,
  -- Set when the node must re-expand, restyle, or redraw at the next commit.
  dirty: boolean,
  handle: uiHost.Node,
  ref: uiHost.Ref?,
  -- The panel a portal node renders its children into.
  overlay: Panel?,
  dead: boolean,
}

export type Mount = {
  adapter: uiHost.Adapter?,
  scheduled: boolean,
  committed: boolean,
  -- Set only while the host calls the adapter's render.
  rendering: boolean,
  submitted: boolean,
  element: uiHost.Element?,
}

export type Panel = {
  name: string,
  owner: plugin.Owner,
  tree: lunette.LayoutTree,
  root: Node?,
  -- The content root's id as the native host root last recorded it.
  rootChild: number?,
  mount: Mount,
  nodes: { [number]: Node },
  nextId: number,
  changes: { lunette.LayoutChange },
  -- Set when a node's state, the theme, or an expansion requires a commit without a framework render.
  dirty: boolean,
  sizing: 'fixed' | 'content',
  maxWidth: number?,
  maxHeight: number?,
  width: number,
  height: number,
  pose: Mat4,
  visible: boolean,
  dead: boolean,
  grabbable: boolean,
  revision: number,
  -- Publishes the size and liveness to the panel's surface.
  sync: () -> (),
  -- Set for a panel that the host made for a portal.
  overlay: Overlay?,
  -- The panel's focused node, and its registration with the session's keyboard focus.
  focused: Node?,
  session: any?,
  presentation: 'world' | 'follow' | 'dialog' | 'attach',
  -- The surface an attached panel sits above, and the gap between them.
  target: vocabulary.Surface?,
  gap: number,
  -- The fixed size last given to the native host root, to restyle it when the size changes.
  rootSize: { number }?,
  -- A dialog's parent panel, and what it blocks.
  parent: Panel?,
  modality: ('panel' | 'session')?,
  -- The follow presentation's current target, which it moves to only when the head turns far enough away.
  followTarget: Mat4?,
}

-- An overlay panel's relation to the portal node that opened it, in another panel.
export type Overlay = {
  portal: Node,
  opener: Panel,
  -- Whether the overlay answers hit queries; tooltips do not.
  hit: boolean,
}

export type Environment = {
  read kind: (name: string) -> Kind,
  read theme: () -> uiHost.Theme,
  -- Runs a kind's or a consumer's function, reporting an error under the label and answering whether it returned.
  read protect: (label: string, run: () -> ()) -> boolean,
  read removed: (Panel, Node) -> (),
  -- Delivers an event to a node's handler, which bubbles it to the node's ancestors by default.
  read dispatch: (Node, uiHost.Event) -> boolean,
  -- Opens or updates the overlay of a portal node with its children, and closes it.
  read portal: (Panel, Node) -> (),
  read unportal: (Node) -> (),
  -- Reports a press on a panel, at the node under it, so overlays outside the press's chain are dismissed.
  read pressed: (Panel, Node?) -> (),
  -- Whether an open modal dialog blocks presses on the panel.
  read blocked: (Panel) -> boolean,
  -- Focuses a node, taking session focus when its policy is text, and answers whether it took focus.
  read focusNode: (Node, boolean) -> boolean,
  read blurNode: (Node) -> (),
}

return {}
