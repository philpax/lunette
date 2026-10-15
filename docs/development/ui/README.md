# UI toolkit design

The UI toolkit builds the session's in-scene interfaces: the plugin manager, the wrist menu, settings panels, titlebars, overlays, and the virtual keyboard. It is a retained tree of composable elements with layout, shaped and wrapped text, a full widget set, physical depth, and input from controllers, tracked hands, and mouse and keyboard. Plugins build interfaces with it through public contracts, and they extend or replace any of its layers through the plugin runtime.

## Reading order

1. [Requirements](requirements.md): what the toolkit provides, the requirements it meets, and what is out of scope.
2. [Architecture](architecture.md): the layers, the data flow from component to pixel, and the split between Rust and Lua.
3. [Authoring](authoring.md): the component model that plugin authors write against.
4. [Extension](extension.md): element kinds, visual overrides, behaviour hooks, outlets, and replacement of providers or frameworks.
5. [Layout and text](layout-and-text.md): units, layout, measurement, shaping, and glyph rendering.
6. [Rendering](rendering.md): drawing in the scene, the toolkit shader, depth, curvature, and draw cost.
7. [Input](input.md): interactors, arbitration, semantic events, focus, and the virtual keyboard.
8. [Presentations](presentations.md): how a panel is placed, scaled, and summoned, and how one tree adapts to different input modes.
9. [Theming](theming.md): tokens, colour roles, typography, elevation, and the guidance behind the defaults.
10. [Testing](testing.md): inspection, addressing by id, and the test layers.
11. [Research](research.md): the systems that informed the design, what was taken from each, and why.

[Migration](migration.md) records the move from the earlier `lunette/ui` toolkit to this design. It is deleted when the migration is complete.

## Terms

The documents use these terms consistently.

- A panel is a UI host object placed in the scene. It has a pose, a size, an optional curvature, and one root of the element tree. A panel is pickable: it registers a `vocabulary.Surface` with the interaction service.
- A presentation is the policy that places, scales, and summons a panel, and that selects which interactors apply to it. A wrist presentation and a summoned presentation can show the same tree.
- A component is a Lua function that receives props and returns elements. Components are the unit that plugin authors write.
- An element is an immutable description returned by a component: an element kind, a key, props, and children.
- A node is the retained object that the host keeps for an element between renders. A node holds layout results, transient interaction state such as hover and press, and drawing caches.
- An element kind is a registered type of node, such as a button, a column, or a third-party knob. A kind defines props, layout behaviour, drawing, event handling, focusability, and inspection output.
- A visual is the drawing function a kind uses for its appearance. Visuals are named and can be overridden without changing behaviour.
- An outlet is a named point in a tree where other plugins contribute subtrees, owned by their own contexts.
- A source is a physical input device: the left or right controller, the left or right tracked hand, or the mouse.
- An interactor is one input mechanism of a source: a controller ray, a hand poke, a hand pinch ray, or a mouse cursor ray.
- A semantic event is a modality-independent event that the host delivers to nodes: hover, press, release, activate, cancel, drag, scroll, and focus changes.
- A token is a named theme value, such as a spacing step, a type style, a colour role, or an elevation level.

## Decisions in brief

- Plugin authors write React-like function components. A reconciler turns their output into a retained node tree. Transient interaction state lives in nodes and never causes a component to render. [Authoring](authoring.md) records the comparison with signals and immediate mode.
- The toolkit is split into a host provider, a registry of element kinds, replaceable visuals, and authoring libraries. The standard widgets register through the same public path as third-party widgets. [Extension](extension.md) describes each layer.
- Layout uses the `taffy` crate through a batched native binding. Text is shaped, wrapped, and measured natively, and glyphs are drawn from a distance field atlas that the text module owns. [Layout and text](layout-and-text.md) describes both.
- Panels draw directly in the scene with real depth. One toolkit shader clips, rounds, bends onto the cylinder, and offsets by elevation. Panels do not render to offscreen textures and do not claim composition layers. [Rendering](rendering.md) records the reasons.
- Sizes are authored in metres. A presentation applies a scale factor so that one tree reads correctly at different viewing distances. [Theming](theming.md) records the reasons for metres over angular units.
- Controller rays, tracked hands, and mouse and keyboard are supported equally. Nodes receive semantic events and never branch on modality. Keyboard and controller focus traversal is a separate channel. [Input](input.md) describes the model.
- In-session interfaces of any size are built with the toolkit rather than as Wayland clients, because they share the session's plugin and owner model, which a Wayland client cannot use.
