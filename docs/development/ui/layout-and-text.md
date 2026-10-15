# Layout and text

## Units and coordinates

Layout uses metres. A node's layout coordinates have their origin at its parent's top-left corner, with x to the right and y downwards, which matches reading order and the layout engine's convention. The host converts local coordinates to the scene through each node's pose, as [Spatial model](spatial-model.md#node-poses) defines, and the toolkit shader applies the conversion. No kind, visual, or component handles the change from y-down to y-up, so no consumer can mirror text by applying it incorrectly.

A presentation scales a whole panel uniformly. Layout runs at authored size, and the scale applies in the panel pose, so a scale change does not relayout or reshape text. [Theming](theming.md#units) explains why sizes are authored in metres and how presentation scale relates to viewing distance.

Depth is not part of layout. Elevation and transforms apply after layout, as [Spatial model](spatial-model.md) describes.

## Layout model

The layout engine is [taffy](https://github.com/DioxusLabs/taffy), a Rust implementation of CSS block, flexbox, and grid layout. The binding pins an exact taffy version and disables taffy's rounding, which is on by default and rounds every position and size to whole units. Layout in metres would otherwise round every box to 0 or 1 metre.

Every box node carries a layout style:

- `display`: flex, grid, block, or none.
- Flex properties: direction, wrap, grow, shrink, and basis.
- Grid properties: template rows and columns, and placement.
- Alignment: align and justify for items, content, and self.
- Spacing: padding, border, margin, and gap. Sizes use the border box.
- Size: width, height, minimum and maximum, and aspect ratio.
- Position: relative or absolute, with insets in logical sides, `start` and `end`, as well as `top` and `bottom`.
- Overflow: visible, clip, or scroll.
- Placement, as [Spatial model](spatial-model.md#placement) defines.

Layout direction is inherited. A subtree with right-to-left direction lays out rows from the right, and the host resolves `start` and `end` to physical sides before it sends styles to the native tree, whether or not the taffy version in use supports direction itself. Directional focus traversal and slider orientation mirror with it.

Components accept spacing and size values as tokens such as `'md'` or as numbers in metres. The host resolves tokens against the panel's theme before sending styles to the native tree, so a theme change that changes spacing relayouts the affected nodes.

The standard kinds `Row`, `Column`, `Stack`, `Grid`, and `Scroll` are boxes with preset styles. They exist for readability, and any box can use any style.

taffy is used rather than a Lua implementation because flexbox and grid have a long correctness tail: intrinsic sizing, min-content and max-content contributions, percentage resolution, and the interaction of grow and shrink with minimum sizes. taffy is used by Bevy, Servo, Slint, Zed, and WayVR's wgui, and it caches layout per node, so relayout after a change touches only dirty subtrees. [Research](research.md#layout-engines) compares it with Yoga, Clay, and morphorm.

## Panel sizing

A panel's size is one of:

- Fixed: the consumer sets width and height, and layout fills them.
- Content: the panel takes its root's max-content size, bounded by a maximum width and height. The backdrop controls and the wrist menu use content sizing.
- User: the user resizes the panel through its resize frame, and layout reflows into the new size. The plugin manager uses user sizing with a minimum size.

A content-sized panel resizes in the commit that changed its content, except while an interactor holds a capture in the panel. The resize then waits until the last capture ends. A slider whose value changes a caption in a content-sized panel would otherwise move under a stationary ray, produce a new value, and resize again. A panel's pose anchor is a presentation property, so a panel anchored at its top edge grows downwards. A size change can animate, as [Motion and feedback](motion-and-feedback.md#layout-transitions) describes.

## Scrolling

A box with `overflow = 'scroll'` keeps a scroll offset as node state. Layout reports the content size, and the host clips the content to the box and offsets it. Scroll input arrives as semantic scroll events and as drag gestures that the scroll box claims, as [Input](input.md#scrolling) describes. The scroll box's physics, including inertia, overscroll, and snap points, is in [Motion and feedback](motion-and-feedback.md#scroll-physics). Its resting offset is clamped to the content after every relayout. A relayout during a drag keeps the content under the interactor rather than clamping the transient offset.

A scroll box exposes its offset and content size as node state, so a scroll indicator reads them without a render.

Long collections use the host's virtualised list and grid kinds. A virtualised kind takes an item count, an item key function, and an item element function, and the host materialises the items inside the viewport and an overscan margin during commit, from the scroll offset it already holds. Scrolling therefore does not render any component. A virtualised kind:

- Needs a fixed item size or a size estimate per item, and corrects estimates after items are measured, keeping the item at the top of the viewport in place.
- Reports its item count to focus traversal and to inspection, so traversal moves past the last materialised item by materialising the next one, and inspection reports every item with its index whether or not it is materialised.
- Keeps an item that holds a capture or focus materialised until the capture ends or focus leaves.
- Scrolls an item into view when traversal or `scrollIntoView` targets it.

## Layout callbacks

Lua takes part in layout in two ways: a leaf kind measures its intrinsic size, and a container with `custom` placement arranges its children. Text is measured natively and never passes through either callback, because text is the most common leaf in every consumer, and measuring it requires shaping.

A leaf kind declares its size with a descriptor when it can. A descriptor is a fixed size, an aspect ratio with a preferred width, or a size that fills the available space, and the native layout evaluates it with no callback. Knobs, swatches, icons, and canvases use descriptors.

A leaf kind whose size depends on its content in another way declares a measure function. A container kind with `custom` placement declares an arrange function. The binding calls them during `tree:compute` through a dispatcher that the host registers by kind id, so the native tree holds no Lua references. Both follow one contract:

- A measure function receives the props, the known dimensions, and the available space on each axis, which is a definite size, min-content, or max-content. It returns a width and a height.
- An arrange function receives the props, the container's size, and a layout context. `context:measure(child, available)` lays out a child's subtree natively and returns its size, and `context:place(child, x, y, transform)` places it. These calls re-enter taffy through the context, which is defined to be safe. A callback that calls the layout tree's own methods raises a typed error, because the tree is borrowed while it computes.
- Each call runs under a protected call. A callback that raises makes its node keep its previous size, or zero on its first layout, and layout completes for the rest of the tree, so the native tree is never left half-updated. The host reports the error against the kind's owner once and dirties the node for the next commit, so the failure is not cached.
- Callbacks cannot yield, render, change state, or call the host. They read only their arguments. A callback that reads a store or the clock produces cached sizes that go stale, so it violates the contract. Taffy calls a measure function several times per node in one pass, once for each axis and sizing mode, and the binding caches results by props version and input.

## Native binding

The native API provides a layout tree type. The host owns one tree per panel and assigns integer node ids.

- `lunette.newLayoutTree()` returns a tree.
- `tree:apply(changes)` applies one commit's changes. `changes` is one array of operations: create a node with a style, set a style, set children, set text content and text style, and remove a node.
- `tree:compute(root, width, height)` lays out the dirty part of the tree and returns one flat array of the nodes whose position relative to the panel or size changed, as consecutive id, x, y, width, and height values in the panel's layout coordinates. taffy reports positions relative to the parent and does not track changes, so the binding composes positions and compares them with the previous computation.
- `tree:textLayout(id)` returns the shaped lines of a text node for drawing, as described in [Glyph rendering](#glyph-rendering).

The shape follows two constraints from the native API. Every handle read returns fresh userdata, and every returned table is a new allocation, so the binding minimises calls and returns flat arrays.

A layout tree is created by Lua and has no compositor counterpart, so it is not a `handle!` handle. Handles carry a control-wire kind and snapshot and dead-handle semantics that a layout tree does not need. The tree is a plain userdata type whose Luau declaration is generated with the rest of `lua/lunette/init.luau`. It is released when the host destroys the panel.

## Text

### Shaping and wrapping

Text is shaped, wrapped, and measured in Rust. LÖVR's `Font` lays out text one codepoint at a time, wraps only at spaces and tabs, has no fallback chain, and does not shape, so the toolkit does not use it for layout. The text module provides:

- Shaping, so ligatures, combining marks, and complex scripts render correctly.
- Line breaking by the Unicode line breaking algorithm, so text wraps at the correct opportunities in every script, and `overflowWrap`, which breaks a word that does not fit on a line of its own.
- Font fallback, so glyphs that the primary face lacks, such as arrows and symbols, come from another face. LÖVR's default font has no arrow glyphs.
- Bidirectional display, so right-to-left text renders in the correct order. Bidirectional editing remains open.
- A language tag per style, which shaping and fallback use.
- Ellipsis and a maximum line count. cosmic-text provides ellipsis; the maximum line count is implemented in the text module. An ellipsised text node shows its full text in a tooltip.
- Inline spans with different styles, such as emphasis, colour, or code, within one text node.

The text module uses [cosmic-text](https://github.com/pop-os/cosmic-text). [parley](https://github.com/linebender/parley) provides the same capabilities with a richer styled-span model and is the text layer of the Linebender stack. cosmic-text is used because it also provides an editor with caret and selection movement, which the text field uses, and because WayVR's wgui uses it in the same domain.

### Styles

A text node has a style from the typography scale: a role such as body, caption, label, title, or code, plus optional overrides for weight, colour, and alignment, and a language tag. Alignment is logical, `start`, `center`, or `end`. [Theming](theming.md#typography) defines the scale. Font families come from the theme. The accessibility text scale multiplies every role's size, as [Accessibility](accessibility.md#settings) describes.

### Glyph rendering

Shaping produces glyph ids, not codepoints. LÖVR's `Font` rasterises glyphs by codepoint and `Pass:text` accepts only strings, so shaped output cannot be drawn through `Pass:text`.

The text module generates multi-channel signed distance field glyphs by glyph id in Rust, packs them into an atlas that it owns, and returns glyph quads that the host draws through the toolkit shader. The clip, surface shape, and elevation logic therefore applies to text exactly as it applies to boxes, and one atlas serves every panel. Glyph outlines come from skrifa, which cosmic-text already depends on. Distance fields are generated by the msdfgen library that LÖVR builds, which Rust links directly as `libmsdfgen` through its C interface.

Generation is bounded per frame:

- The font database is built at startup, not on the first measurement, because enumerating and parsing system fonts takes far longer than a frame.
- Glyph generation has a per-frame budget. A glyph not yet generated draws as a placeholder until it is ready, so a window title in a script with many new glyphs does not stall a frame.
- The atlas is paged. A glyph keeps its page and coordinates for its lifetime, so instance data that refers to it stays valid as the atlas grows. Glyphs are reference-counted by the shaped runs that use them, and only unreferenced glyphs are evicted. The atlas has a size limit, and it does not grow across source reloads.

A LÖVR fork patch that rasterises and draws glyphs by id is the alternative. It would reuse LÖVR's atlas, but it would couple the toolkit to LÖVR's atlas management, including its per-glyph lookup lock, and it would leave text as the one primitive that does not go through the toolkit shader.

Multi-channel signed distance fields keep glyphs sharp across the range of distances and scales that a VR panel sees. They round sharp corners at very small sizes and cannot apply hinting. The minimum text size keeps text above the range where that matters, and the shader computes the edge width from screen-space derivatives, so edges stay antialiased at any distance.

### Fonts

The toolkit ships a default UI family with wide script coverage and a symbol fallback, and an icon font. Icons are glyphs in the same text path, so they wrap, align, scale, and colour with text. System fonts are available through the fallback chain. Licences and attribution are recorded in [CREDITS.md](../../../CREDITS.md) when the fonts are added.

Colour emoji have no distance field representation. A colour font with outlines, such as a COLR font, renders its outlines in a single colour. A bitmap-only colour font, such as a CBDT font, has no outlines, so its glyphs fall through to the next face in the fallback chain, or to the missing-glyph box. A bitmap glyph path is an open question.

### Text editing

The text field kind keeps the edited text, caret, and selection as node state. Caret movement, selection, and hit testing from a pointer position use the native editor, so they follow grapheme clusters and shaped positions. Multi-line text areas use the same kind with wrapping enabled.

Read-only selectable text uses the same selection model without editing. Copying goes through the session clipboard service, which bridges to the Wayland selection, so text copied from a toolkit panel pastes into a client window.

## Open questions

- Bidirectional editing: caret movement through mixed-direction text, and selection rendering across direction runs.
- Input-method composition. The focus service has no preedit path.
- Whether the distance field atlas uses one em size for all text, or a small set of sizes for caption and title text.
- A bitmap glyph path for colour emoji.
- Hyphenation for long compound words in narrow columns.
- The default UI family. It needs broad coverage, legible shapes at small angular sizes, and a licence compatible with GPL-3.0-only redistribution.
