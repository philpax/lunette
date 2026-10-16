-- The host's private records for kinds, nodes, and panels.

local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local uiHost = require '@lunette-contracts/ui-host'

export type Kind = {
  name: string,
  owner: plugin.Owner,
  registration: uiHost.KindRegistration,
  composite: boolean,
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
  host: { hovers: number, pressed: boolean, dragging: boolean },
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
}

export type Environment = {
  read kind: (name: string) -> Kind,
  read theme: () -> uiHost.Theme,
  -- Runs a kind's or a consumer's function, reporting an error under the label and answering whether it returned.
  read protect: (label: string, run: () -> ()) -> boolean,
  read removed: (Panel, Node) -> (),
  -- Delivers an event to a node's handler, which bubbles it to the node's ancestors by default.
  read dispatch: (Node, uiHost.Event) -> (),
}

return {}
