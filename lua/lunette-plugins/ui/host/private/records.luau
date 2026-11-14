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
  -- The host's outlet kind renders the contributions to an outlet as its children.
  outlet: boolean,
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
  | {
    kind: 'volume',
    x: number,
    y: number,
    width: number,
    height: number,
    offset: number,
    depth: number,
    draw: (Pass, uiHost.Volume) -> (),
    -- Set when the callback raised, so that it is not called again until the visual runs again.
    failed: boolean,
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
  -- Animation channels by name: opacity, elevation, progress, and others visuals read.
  channels: { [string]: Channel },
  -- Set when the node must re-expand, restyle, or redraw at the next commit.
  dirty: boolean,
  handle: uiHost.Node,
  ref: uiHost.Ref?,
  -- The panel a portal node renders its children into.
  overlay: Panel?,
  -- The outlet instance an outlet node holds.
  placement: Placement?,
  dead: boolean,
}

export type Mount = {
  adapter: uiHost.Adapter?,
  scheduled: boolean,
  committed: boolean,
  -- Set only while the host calls the adapter's render.
  rendering: boolean,
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
  -- An attached panel's least width: its target's width.
  minWidth: number?,
  maxHeight: number?,
  width: number,
  height: number,
  pose: Mat4,
  visible: boolean,
  dead: boolean,
  grabbable: boolean,
  revision: number,
  -- Publishes the size, liveness, and surface properties to the panel's surface.
  sync: () -> (),
  -- The options the panel was made with, nil for an overlay panel, and the public handle of a top-level panel.
  options: uiHost.PanelOptions?,
  handle: uiHost.Panel?,
  -- The panel's shared properties. A commit notifies the properties listeners; a preview does not. A preview is a
  -- curve change the Settings control shows while its slider is held; the value is applied but not saved.
  locked: boolean,
  transformLocked: boolean,
  setCurve: (Panel, number, number?, boolean?) -> (),
  setLocked: (Panel, boolean, boolean?) -> (),
  setTransformLocked: (Panel, boolean, boolean?) -> (),
  -- Set for a panel that the host made for a portal.
  overlay: Overlay?,
  -- The panel's focused node, and its registration with the session's keyboard focus.
  focused: Node?,
  session: any?,
  presentation: 'world' | 'follow' | 'dialog' | 'attach',
  -- The panel bends as a cylinder of radius 1 / |curve|, towards the viewer when positive and away when negative, about
  -- an axis turned anticlockwise from the panel's vertical by curveAxis radians; zero is flat.
  curve: number,
  curveAxis: number,
  -- A uniform zoom about the panel's centre. Layout stays in unscaled metres; drawing and hit testing scale them.
  scale: number,
  -- The surface an attached panel sits above, and the gap between them.
  target: vocabulary.Surface?,
  gap: number,
  -- The fixed size last given to the native host root, to restyle it when the size changes.
  rootSize: { number }?,
  -- A dialog's parent panel, and what it blocks.
  parent: Panel?,
  modality: ('panel' | 'session')?,
  -- The panel's own fade, for panels that fade in and out, and the ghosts of exiting nodes.
  fade: Channel?,
  -- The opacity its owner asks for, which multiplies the host's own fade.
  opacity: Channel,
  ghosts: { Ghost },
  -- Set while a panel fades out before it is destroyed; it takes no hits.
  closing: boolean,
  -- An essential panel stays shown while panels are hidden together; a suppressed one is hidden by that.
  essential: boolean,
  suppressed: boolean,
  -- The follow presentation's current target, which it moves to only when the head turns far enough away.
  followTarget: Mat4?,
  -- Set for a world panel made without a pose, until the host places it ahead of the head or its owner poses it.
  placeAhead: boolean?,
  -- Set for a world panel made grabbable, which placement memory remembers by the panel's name.
  remembered: boolean?,
  -- The surface's placement key: the panel's name for a remembered panel, or what its owner sets.
  placementKey: string?,
  -- The outlet instances placed in the panel, whose contributions render in its commits.
  placements: { Placement },
}

-- A live contribution to an outlet, by its owner.
export type Contribution = {
  outlet: string,
  owner: plugin.Owner,
  -- The definition name of the contributing plugin, which attribution shows and ordering compares.
  contributor: string,
  version: uiHost.Version,
  bind: (uiHost.OutletMount) -> (),
  -- The order of registration, which keeps two contributions from one plugin in their order.
  sequence: number,
}

-- One contribution's mount point within one placement.
export type ContributionMount = {
  contribution: Contribution,
  handle: uiHost.OutletMount,
  adapter: uiHost.Adapter?,
  scheduled: boolean,
  committed: boolean,
  rendering: boolean,
  dead: boolean,
  -- The element the contribution last submitted, and the wrapper the host built around it.
  element: uiHost.Element?,
  wrapped: uiHost.Element?,
  wrapper: uiHost.Element?,
  -- The key of the wrapper among the outlet's children.
  key: string,
}

-- An outlet instance: an outlet node, the declaration it places, its validated props, and a mount point for each
-- compatible contribution in order.
export type Placement = {
  node: Node,
  declaration: uiHost.Outlet<any>?,
  -- Whether the declaration conflicts with a live declaration of the same name and version.
  conflicting: boolean,
  raw: unknown,
  props: uiHost.Props,
  mounts: { ContributionMount },
  -- Contributions whose version mismatch has been reported for this placement.
  reported: { [Contribution]: boolean },
}

export type Channel = { value: number, target: number, velocity: number }

-- The drawing an exiting node leaves while it fades: its subtree's primitives at their last positions.
export type GhostNode = {
  primitives: { Primitive },
  x: number,
  y: number,
  z: number,
  parentSurface: number,
  clip: { number }?,
}

export type Ghost = { opacity: Channel, nodes: { GhostNode } }

-- An overlay panel's relation to the portal node that opened it, in another panel.
export type Overlay = {
  portal: Node,
  opener: Panel,
  -- Whether the overlay answers hit queries; tooltips do not.
  hit: boolean,
  -- A sticky overlay is parented to the panel its opener is attached to, or to the opener: it keeps the local pose it
  -- opened at, so moving or turning that panel carries it along while a bend that only moves the opener's surface
  -- neither moves nor turns it. Its contents may change, such as a Settings bend while the panel bends.
  sticky: boolean,
  -- The opening pose in that parent's basis, which a sticky overlay keeps.
  localPose: Mat4?,
}

export type Environment = {
  read kind: (name: string) -> Kind,
  read theme: () -> uiHost.Theme,
  -- Runs a kind's or a consumer's function, reporting an error under the label and answering whether it returned.
  read protect: (label: string, run: () -> ()) -> boolean,
  read removed: (Panel, Node) -> (),
  -- Moves pointer captures and hover from a node to the node that replaces it under a changed registration.
  read carried: (from: Node, to: Node) -> (),
  -- Delivers an event to a node's handler, which bubbles it to the node's ancestors by default.
  read dispatch: (Node, uiHost.Event) -> boolean,
  -- Opens or updates the overlay of a portal node with its children, and closes it.
  read portal: (Panel, Node) -> (),
  read unportal: (Node) -> (),
  -- Reports a press on a panel, at the node under it, so overlays outside the press's chain are dismissed.
  read pressed: (Panel, Node?) -> (),
  -- Whether an open modal dialog blocks presses on the panel.
  read blocked: (Panel) -> boolean,
  -- A committed property change on a top-level panel: the properties listeners hear it, and the store saves from it.
  read changed: (Panel) -> (),
  -- Cancels content input on a panel as its input lock engages: content captures, hover, focus, and touch.
  read cancelContent: (Panel) -> (),
  -- Whether presses give haptic feedback.
  read haptics: () -> boolean,
  -- Pulses each pointer that holds the node, when haptics are on.
  read pulse: (Node, 'detent') -> (),
  -- Focuses a node, taking session focus when its policy is text, and answers whether it took focus.
  read focusNode: (Node, boolean) -> boolean,
  read blurNode: (Node) -> (),
  -- The children of an outlet node: a wrapper around each contribution's content, with its slots.
  read outlet: (Panel, Node) -> ({ uiHost.Element }, { string }),
}

return {}
