# Layout and text

## Units and coordinates

Layout uses metres. A panel's layout coordinates have their origin at the panel's top-left corner, with x to the right and y downwards, which matches reading order and the layout engine's convention. The host converts panel-local coordinates to the scene's y-up space in the toolkit shader. No kind, visual, or component handles that conversion, so no consumer can mirror text by applying the flip incorrectly.

A presentation scales a whole panel uniformly. Layout runs at authored size, and the scale applies in the panel transform, so a scale change does not relayout or reshape text. [Theming](theming.md#units) explains why sizes are authored in metres and how presentation scale relates to viewing distance.

Depth is not part of layout. Elevation is a node property that the renderer applies along the panel's normal, as [Rendering](rendering.md#depth) describes.

## Layout model

The layout engine is [taffy](https://github.com/DioxusLabs/taffy), a Rust implementation of CSS block, flexbox, and grid layout. Every box node carries a layout style:

- `display`: flex, grid, block, or none.
- Flex properties: direction, wrap, grow, shrink, and basis.
- Grid properties: template rows and columns, and placement.
- Alignment: align and justify for items, content, and self.
- Spacing: padding, margin, and gap.
- Size: width, height, minimum and maximum, and aspect ratio.
- Position: relative or absolute, with insets.
- Overflow: visible, clip, or scroll.

Components accept spacing and size values as tokens such as `'md'` or as numbers in metres. The host resolves tokens against the panel's theme before sending styles to the native tree, so a theme change that changes spacing relayouts the affected nodes.

The standard kinds `Row`, `Column`, `Stack`, `Grid`, and `Scroll` are boxes with preset styles. They exist for readability, and any box can use any style.

taffy was chosen over a Lua implementation because flexbox and grid have a long correctness tail: intrinsic sizing, min-content and max-content contributions, percentage resolution, and the interaction of grow and shrink with minimum sizes. taffy is used by Bevy, Servo, Slint, Zed, and WayVR's wgui, and it caches layout per node, so relayout after a change touches only dirty subtrees. [Research](research.md#layout-engines) compares it with Yoga, Clay, and morphorm.

## Panel sizing

A panel's size is one of:

- Fixed: the consumer sets width and height, and layout fills them.
- Content: the panel takes its root's max-content size, bounded by a maximum width and height. The backdrop controls and the wrist menu use content sizing.
- User: the user resizes the panel through its frame, and layout reflows into the new size. The plugin manager uses user sizing with a minimum size.

A content-sized panel resizes in the same commit as the layout change that caused it. Its pose anchor is a presentation property, so a panel anchored at its top edge grows downwards.

## Scrolling

A box with `overflow = 'scroll'` keeps a scroll offset as node state. Layout reports the content size, and the host clips the content to the box and offsets it. Scroll input arrives as semantic scroll events from thumbsticks, mouse wheels, and drag gestures, as [Input](input.md#scrolling) describes. A scroll offset is clamped to the content after every relayout.

A long list uses a virtualised list kind that renders only the rows inside the viewport and an overscan margin. It needs a fixed row height or a per-row size estimate, and it corrects estimates as rows are measured. Virtualisation is a component concern: the virtualised list renders a window of child components, and the host lays out only the rows that exist.

## Measurement

Text nodes are measured natively. The native text module shapes and wraps the text at the available width and returns its size, and taffy caches the result per node and constraint. Text is the most common leaf in every consumer, and measuring it requires shaping, so routing it through Lua would mean one call from Rust into Lua per text node per constraint during layout.

Third-party leaf kinds can declare a Lua measure function. The native layout pass calls it through mlua during computation, and taffy caches the result. This is supported for custom kinds such as a knob or a graph canvas, which are few per panel. A measure function must be pure: it reads props and returns a size, and it cannot render, change state, or call the host.

## Native binding

The native API provides a layout tree handle. The host owns one tree per panel and assigns integer node ids.

- `lunette.newLayoutTree()` returns a tree handle.
- `tree:apply(changes)` applies one commit's changes. `changes` is one array of operations: create a node with a style, set a style, set children, set text content and text style, and remove a node.
- `tree:compute(root, width, height)` lays out the dirty part of the tree and returns one flat array of the nodes whose layout changed, as consecutive id, x, y, width, and height values.
- `tree:textLayout(id)` returns the shaped lines of a text node for drawing, as described in [Glyph rendering](#glyph-rendering).

The shape follows two constraints from the native API. Every handle read returns fresh userdata, and every returned table is a new allocation, so the binding minimises calls and returns flat arrays. The binding follows the existing `module!` and `handle!` declaration pattern, so the Luau declarations are generated with the rest of `lua/lunette/init.luau`.

## Text

### Shaping and wrapping

Text is shaped, wrapped, and measured in Rust. LÖVR's `Font` lays out text one codepoint at a time, wraps only at spaces and tabs, has no fallback chain, and does not shape, so the toolkit does not use it for layout. The text module provides:

- Shaping, so ligatures, combining marks, and complex scripts render correctly.
- Line breaking by the Unicode line breaking algorithm, so text wraps at the correct opportunities in every script.
- Font fallback, so glyphs that the primary face lacks, such as arrows and symbols, come from another face. LÖVR's default font has no arrow glyphs.
- Bidirectional display, so right-to-left text renders in the correct order. Bidirectional editing remains open.
- Ellipsis and a maximum line count.
- Inline spans with different styles, such as emphasis, colour, or code, within one text node.

The text module uses [cosmic-text](https://github.com/pop-os/cosmic-text). [parley](https://github.com/linebender/parley) provides the same capabilities with a richer styled-span model and is the text layer of the Linebender stack. cosmic-text is used because it also provides an editor with caret and selection movement, which the text field uses, and because WayVR's wgui uses it in the same domain.

### Styles

A text node has a style from the typography scale: a role such as body, caption, label, title, or code, plus optional overrides for weight, colour, and alignment. [Theming](theming.md#typography) defines the scale. Font families come from the theme.

### Glyph rendering

Shaping produces glyph ids, not codepoints. LÖVR's `Font` rasterises glyphs by codepoint and `Pass:text` accepts only strings, so shaped output cannot be drawn through `Pass:text`.

The text module generates multi-channel signed distance field glyphs by glyph id in Rust, packs them into an atlas texture that it owns, and returns glyph quads that the host draws through the toolkit shader. The clip, curvature, and elevation logic therefore applies to text exactly as it applies to boxes, and one atlas serves every panel. Distance field generation uses the msdfgen library that LÖVR already builds.

A LÖVR fork patch that rasterises and draws glyphs by id is the alternative. It would reuse LÖVR's atlas, but it would couple the toolkit to LÖVR's atlas management, including its per-glyph lookup lock, and it would leave text as the one primitive that does not go through the toolkit shader.

Multi-channel signed distance fields keep glyphs sharp across the range of distances and scales that a VR panel sees. They round sharp corners at very small sizes and cannot apply hinting. The theme's minimum text size keeps text above the range where that matters.

### Fonts

The toolkit ships a default UI family with wide script coverage and a symbol fallback, and an icon font. Icons are glyphs in the same text path, so they wrap, align, scale, and colour with text. System fonts are available through the fallback chain. Licences and attribution are recorded in [CREDITS.md](../../../CREDITS.md) when the fonts are added.

Colour emoji are bitmaps and cannot be represented as distance fields. They render in monochrome until a bitmap glyph path exists.

### Text editing

The text field kind keeps the edited text, caret, and selection as node state. Caret movement, selection, and hit testing from a pointer position use the native editor, so they follow grapheme clusters and shaped positions. Multi-line text areas use the same kind with wrapping enabled.

## Open questions

- Bidirectional editing: caret movement through mixed-direction text, and selection rendering across direction runs.
- Input-method composition. The focus service has no preedit path.
- Whether the distance field atlas uses one em size for all text, or a small set of sizes for caption and title text.
- The default UI family. It needs broad coverage, legible shapes at small angular sizes, and a licence compatible with GPL-3.0-only redistribution.
