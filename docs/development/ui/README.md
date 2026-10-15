# UI toolkit design

The UI toolkit builds the session's in-scene interfaces: the plugin manager, the wrist menu, settings panels, titlebars, overlays, notifications, and the virtual keyboard. It is a retained tree of composable elements with layout, shaped and wrapped text, a full widget set, physical depth, animation, and input from controllers, tracked hands, and mouse and keyboard. Plugins build interfaces with it through public contracts, and they extend or replace any of its layers through the plugin runtime.

## Reading order

1. [Requirements](requirements.md): what the toolkit provides, the requirements it meets, and what is out of scope.
2. [Architecture](architecture.md): the layers, the host's responsibilities, the data flow from component to pixel, and the split between Rust and Lua.
3. [Spatial model](spatial-model.md): node poses, surface shapes, placement, anchors, and hit volumes.
4. [Authoring](authoring.md): the component model that plugin authors write against.
5. [Extension](extension.md): the element format, element kinds, visuals, behaviour overrides, outlets, replacement, other frameworks, and trust.
6. [Layout and text](layout-and-text.md): units, layout, layout callbacks, shaping, and glyph rendering.
7. [Rendering](rendering.md): drawing in the scene, the toolkit shader, the drawing API, bound parameters, depth and draw order, opacity, and draw cost.
8. [Input](input.md): sources and interactors, routing, gestures, capture, focus, and the virtual keyboard.
9. [Presentations](presentations.md): pose policies, portals and overlays, notifications, and input modes.
10. [Motion and feedback](motion-and-feedback.md): the animation clock, transitions, scroll physics, and haptic, sound, and visual feedback.
11. [Theming](theming.md): tokens, target sizes, typography, colours, and elevation.
12. [Accessibility](accessibility.md): session settings, roles, one-hand use, and localisation.
13. [Testing](testing.md): inspection, addressing by id, and the test layers.
14. [Research](research.md): the systems that informed the design, what was taken from each, and why.

[Migration](migration.md) records the move from the earlier `lunette/ui` toolkit to this design. It is deleted when the migration is complete.

## Terms

The documents use these terms consistently.

- A panel is a UI host object placed in the scene. It has a pose, a size, a surface shape, and one root of the element tree. A panel is pickable: it registers a surface with the interaction service.
- A presentation is the policy that places, scales, and summons a panel, and that selects which interactors apply to it. A wrist presentation and a summoned presentation can show the same tree.
- A component is a Lua function that receives props and returns elements. Components are the unit that authors of the standard authoring library write.
- An element is an immutable description of a node: an element kind, a key, props, and children. The host defines the element format, and every authoring framework produces it.
- A node is the retained object that the host keeps for an element. A node holds layout results, its pose, transient interaction state such as hover and press, animation channels, and drawing caches.
- An element kind is a registered type of node, such as a button, a column, or a third-party knob. A kind defines props, layout behaviour, drawing, event handling, focusability, a role, and inspection output. A composite kind expands into other elements.
- A visual is a drawing function that a kind uses for its appearance. Visuals are named and can be overridden without changing behaviour.
- An outlet is a named, typed point in a tree where other plugins contribute subtrees, owned by their own contexts.
- A portal renders an element into another panel while keeping its logical parent. Overlays are portals.
- A surface shape maps points on a surface to the scene. Flat and cylindrical panels are surface shapes.
- A surface root is a node that opens a surface, such as a panel root. Its descendants are positioned in its surface coordinates.
- A mount point is a node into which one authoring framework renders, such as a panel root, an outlet instance, a portal, or a virtualised item.
- A source is a physical input device: the left or right hand, which holds a controller or is tracked bare, or the mouse.
- An interactor is one input mechanism of a source: a controller ray, a fingertip poke point, a pinch ray, a grab sphere, or a mouse cursor ray.
- A semantic event is a modality-independent event that the host delivers to nodes, such as hover, press, activate, drag, scroll, and focus changes.
- A gesture claim is a node's declaration that it consumes a kind of drag or scroll, used to decide which node a gesture belongs to.
- A token is a named theme value, such as a spacing step, a type style, a colour role, an elevation level, or a motion role.

## Decisions in brief

- Plugin authors write React-like function components. A reconciler turns their output into host elements. Transient interaction state lives in nodes and never causes a component to render. [Authoring](authoring.md) records the comparison with signals and immediate mode.
- The host owns the element format, the node tree, composite expansion, layout, drawing, hit testing, routing, focus, portals, and inspection. Element kinds, visuals, and authoring frameworks are layers above it, and the standard widgets register through the same public path as third-party widgets. [Extension](extension.md) describes each layer.
- Every node is positioned in the coordinates of its surface root and either bends onto the surface or keeps a rigid frame of its own. Flat and cylindrical sheets are the common case of that model, not its limit. [Spatial model](spatial-model.md) defines it.
- Layout uses the `taffy` crate's low-level API through a batched native binding, so custom layouts written in Lua take part in intrinsic sizing. Text is shaped, wrapped, and measured natively, and glyphs are drawn from a distance field atlas that the text module owns. [Layout and text](layout-and-text.md) describes both.
- Panels draw directly in the scene with real depth, in tree order. One toolkit shader clips, rounds, maps onto the surface shape, offsets by elevation, and evaluates parameters bound to animation and to nearby interactors. Panels do not render to offscreen textures and do not claim composition layers. [Rendering](rendering.md) records the reasons.
- Sizes are authored in metres. A presentation applies a scale factor so that one tree reads correctly at different viewing distances. Touch parameters stay physical at every scale. [Theming](theming.md) records the reasons for metres over angular units.
- Controller rays, tracked hands, and mouse and keyboard are supported equally. Nodes receive semantic events and never branch on modality. Keyboard and controller focus traversal is a separate channel that a plugin can drive. [Input](input.md) describes the model.
- Overlays are separate panels opened through portals, anchored to their opener in the manner of Wayland's `xdg_popup`. [Presentations](presentations.md#portals-and-overlays) defines their capture, dismissal, focus, and modality.
- In-session interfaces of any size are built with the toolkit rather than as Wayland clients, because they share the session's plugin and owner model, which a Wayland client cannot use.
