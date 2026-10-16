# Layout and text

## Units and coordinates

Layout uses metres. Layout positions are in the coordinates of a node's surface root, with the origin at its top-left corner, `u` to the right, and `v` downwards, which matches reading order and the layout engine's convention. The host maps surface coordinates to the scene through the surface's shape, as [Spatial model](spatial-model.md#surface-roots) defines, and the toolkit shader applies the mapping. No kind, visual, or component handles the change from y-down to y-up, so no consumer can mirror text by applying it incorrectly.

A presentation scales a whole panel uniformly. Layout runs at authored size, and the scale applies in the panel pose, so a scale change does not relayout or reshape text. [Theming](theming.md#units) explains why sizes are authored in metres and how presentation scale relates to viewing distance.

Depth is not part of layout. Elevation and transforms apply after layout, as [Spatial model](spatial-model.md) describes.

## Layout model

The layout engine is [taffy](https://github.com/DioxusLabs/taffy), a Rust implementation of CSS block, flexbox, and grid layout. The binding pins an exact taffy version, because taffy's 0.x releases change its API. It never applies taffy's rounding pass, which rounds every position and size to whole units and would round every box laid out in metres to 0 or 1 metre.

Every box node carries a layout style:

- `display`: flex, grid, block, or none.
- Flex properties: direction, wrap, grow, shrink, and basis.
- Grid properties: template rows and columns, and placement.
- Alignment: align and justify for items, content, and self.
- Spacing: padding, border, margin, and gap. Sizes use the border box.
- Size: width, height, minimum and maximum, and aspect ratio.
- Position: relative or absolute, with insets.
- Overflow: visible, clip, or scroll.
- Direction: left-to-right or right-to-left, inherited.
- Placement, as [Spatial model](spatial-model.md#placement) defines.

A subtree with right-to-left direction lays out rows from the right. taffy implements direction for block, flexbox, and grid. Directional focus traversal and slider orientation mirror with it.

Components accept spacing and size values as tokens such as `'md'` or as numbers in metres. The host resolves tokens against the panel's theme before sending styles to the native tree, so a theme change that changes spacing relayouts the affected nodes.

The standard kinds `Row`, `Column`, `Stack`, `Grid`, and `Scroll` are boxes with preset styles. They exist for readability, and any box can use any style.

taffy is used rather than a Lua implementation because flexbox and grid have a long correctness tail: intrinsic sizing, min-content and max-content contributions, percentage resolution, and the interaction of grow and shrink with minimum sizes. taffy is used by Bevy, Servo, Slint, Zed, and WayVR's wgui, and it caches layout per node, so relayout after a change touches only dirty subtrees. [Research](research.md#layout-engines) compares it with Yoga, Clay, and morphorm.

## Panel sizing

A panel's size is one of:

- Fixed: the consumer sets width and height, and layout fills them.
- Content: the panel takes its root's max-content size, bounded by a maximum width and height. The backdrop controls and the wrist menu use content sizing.
- User: the user resizes the panel through its resize frame, and layout reflows into the new size. The plugin manager uses user sizing with a minimum size.

A content-sized panel resizes in the commit that changed its content. While an interactor holds a capture in the panel, the resize waits until the capture ends or for at most a short timeout, whichever comes first, so a resting pinch cannot hold it indefinitely. Content inside the panel can still reflow during a capture, so a captured control computes its values in its own frame as it was when the drag started, as [Input](input.md#semantic-events) describes. A slider whose value changes a neighbouring caption therefore does not move under a stationary ray and produce a new value.

A panel's pose anchor is a presentation property, so a panel anchored at its top edge grows downwards. A size change can animate, as [Motion and feedback](motion-and-feedback.md#layout-transitions) describes.

## Scrolling

A box with `overflow = 'scroll'` keeps a scroll offset as node state. Layout reports the content size, and the host clips the content to the box and offsets it. Scroll input arrives as semantic scroll events and as drag gestures that the scroll box claims, as [Input](input.md#scrolling) describes. The scroll box's physics, including inertia, overscroll, and snap points, is in [Motion and feedback](motion-and-feedback.md#scroll-physics). Its resting offset is clamped to the content after every relayout. A relayout during a drag keeps the content under the interactor rather than clamping the transient offset.

A scroll box draws its own scroll indicator and publishes its thumb and track as items. Dragging the thumb scrolls proportionally, and pressing the track pages towards the press, so a ray user has a precise way to scroll without dragging content. The indicator is part of the scroll box's visual, so a theme restyles it through that visual, and tests address it as the scroll box's id followed by `@thumb` or `@track`. The node handle offers `scrollTo`, `scrollBy`, and `scrollIntoView` for programmatic scrolling.

Long collections use the host's virtualised list and grid kinds. A virtualised kind takes an item count and an item key function. Each materialised item is a mount point, into which the authoring framework renders the item's component, so an item can hold state and read stores. The host materialises the items inside the viewport and an overscan margin during commit, from the scroll offset it already holds, so scrolling renders only the components of items that enter the viewport. A virtualised kind:

- Needs a fixed item size or a size estimate per item, and corrects estimates after items are measured, keeping the item at the top of the viewport in place.
- Reports its item count to focus traversal and to inspection, so traversal moves past the last materialised item by materialising the next one, and inspection reports every item with its index whether or not it is materialised.
- Keeps an item materialised while it holds a capture or focus, or owns an open portal such as a context menu or a dialog, until that ends. If the item's key leaves the data while it holds focus, focus moves to the nearest remaining item.
- Schedules materialisation when scrolling crosses the overscan boundary, so a fling never shows blank rows. Estimate correction runs a bounded number of passes per commit, and materialisation has a render budget per frame, beyond which further items appear on the next frame.
- Accepts items as mount points that a framework renders into, or as host elements from a `renderItem(index, key)` function, which composites use.
- Scrolls an item into view when traversal or `scrollIntoView` targets it.
- Does not play exit animations for items that scroll out of view, because leaving the viewport is not removal.

A table is a virtualised list whose rows share a column model: the header declares each column's width, as a fixed size, a fraction, or a minimum, and every row lays out its cells against those widths. Columns therefore stay aligned as rows materialise, and a column resize drag changes the model rather than each row. Column widths cannot depend on the content of rows that are not materialised, so a column sized to its content measures only the materialised rows and keeps the largest width it has seen. The header stays in place while rows scroll vertically, a pinned first column stays in place under horizontal scrolling, and a sortable column's header carries its sort direction as semantics.

## Scripted layout

A container with `scripted` placement is a layout algorithm written in Lua. It runs inside taffy's layout passes, so it takes part in intrinsic sizing like flexbox and grid do: a radial menu inside a flex row reports a min-content and max-content size computed from its children.

```luau
layout = {
  kind = 'scripted',
  layout = function(props, children, input, ctx)
    local largest = 0
    for _, child in children do
      local w, h = ctx:measure(child, { width = 'max-content', height = 'max-content' })
      largest = math.max(largest, w, h)
    end
    local size = 2 * (props.radius + largest)
    if input.perform then
      for i, child in children do
        local angle = (i - 1) / #children * 2 * math.pi
        ctx:place(child, size / 2 + props.radius * math.cos(angle), size / 2 + props.radius * math.sin(angle))
      end
    end
    return size, size
  end,
}
```

`input` carries the known dimensions, the available space on each axis as a definite size, min-content, or max-content, and whether taffy asks only for a size or for the final layout. The same function answers taffy's sizing passes and its final pass, in the manner of the CSS Layout API's intrinsic sizes and layout callbacks. `ctx:measure(child, available)` computes a child's size without laying it out. `ctx:place(child, u, v, transform, size)` is valid only in the final pass: it lays the child's subtree out at the given size, or at its measured size, and positions it. The transform becomes the child's layout transform, as [Spatial model](spatial-model.md#composition) defines, so a radial menu's labels can be rotated. A scripted container is the containing block for its children's absolutely positioned descendants, which it lays out after placing its children.

A leaf kind declares its size with a descriptor when it can: a fixed size, an aspect ratio with a preferred width, or a size that fills the available space. The native layout evaluates a descriptor with no callback. Knobs, swatches, icons, and canvases use descriptors. A leaf whose size depends on its content in another way declares a measure function, which receives the same `input` and returns a width and a height.

Text is measured natively and never passes through a Lua callback, because text is the most common leaf in every consumer, and measuring it requires shaping.

Custom layout and measure functions follow one contract:

- The binding calls them during `tree:compute` through a dispatcher that the host registers by kind id, so the native tree holds no Lua references.
- `ctx` is a scoped userdata that wraps the tree's borrow, together with the Lua state and the dispatcher, for the duration of the call, so `ctx:measure` and `ctx:place` re-enter the layout computation legally. A `ctx` used after its call returns raises. The tree's own methods raise a typed error while it computes, so a callback cannot re-enter it any other way. Scripted layouts nest to a fixed depth, because each level crosses from Rust to Lua and back, and a deeper scripted layout is laid out as a fixed-size leaf with an error reported against its kind's owner.
- Each call runs under a protected call. A callback that raises makes its node keep its previous size, or zero on its first layout, and layout completes for the rest of the tree, so the native tree is never left half-updated. The host reports the error against the kind's owner, and the node is retried at the next commit that changes its props or its children.
- Callbacks cannot yield, render, change state, or call the host, and the host functions check a layout-phase flag to enforce it. They read only their arguments. A layout that needs state that changes over time, such as a force-directed graph, is a component that computes positions and sets its children's transforms.
- taffy calls a layout function several times per node in one pass, once for each axis and sizing mode. Results are cached in taffy's per-node cache. A change of a node's props clears the cache of the node and of every ancestor, because each ancestor's layout may depend on it.

## Native binding

The native API provides a layout tree type. The host owns one tree per panel and assigns integer node ids.

- `lunette.newLayoutTree()` returns a tree.
- `tree:apply(changes)` applies one commit's changes. `changes` is one array of operations: create a node with a style and kind, set a style, set children, set text content and text style, and remove a node.
- `tree:compute(root, width, height)` lays out the dirty part of the tree and returns one flat array of the nodes whose position in surface coordinates, size, or layout transform changed, as consecutive id, u, v, width, height, and transform values.
- `tree:textLayout(id)` returns the shaped lines of a text node for drawing, and the geometry of its spans.

The tree implements taffy's low-level layout traits over its own node storage rather than using taffy's ready-made `TaffyTree`: traversal, style access for each container kind, the layout cache, the containing-block trait that absolutely positioned boxes need, and `compute_child_layout`, which dispatches each node to taffy's flexbox, grid, or block algorithm, to native text measurement, or to the Lua dispatcher for scripted layouts and measure functions. Owning the storage lets the tree record which nodes changed as it computes. A node whose own layout is cached but whose ancestor moved is not visited by taffy, so after each computation the tree walks the subtrees of moved nodes to compose their surface coordinates. `compute` therefore returns composed positions without comparing the whole tree. Moving to a new taffy version means updating the trait implementations, at a time the project chooses.

The shape of the binding follows two constraints from the native API. Every handle read returns fresh userdata, and every returned table is a new allocation, so the binding minimises calls and returns flat arrays.

A layout tree is created by Lua and has no compositor counterpart, so it is not a `handle!` handle, which carries a control-wire kind and snapshot and dead-handle semantics. It is a plain userdata type in the manner of `AudioBlock`, whose Luau declaration is generated with the rest of `lua/lunette/init.luau`. Its methods use interior mutability. It is released when the host destroys the panel.

## Text

### Shaping and wrapping

Text is shaped, wrapped, and measured in Rust. LÖVR's `Font` lays out text one codepoint at a time, wraps only at spaces and tabs, has no fallback chain, and does not shape, so the toolkit does not use it for layout. The text module provides:

- Shaping, so ligatures, combining marks, and complex scripts render correctly.
- Line breaking by the Unicode line breaking algorithm, so text wraps at the correct opportunities in every script, and `overflowWrap`, which breaks a word that does not fit on a line of its own.
- Font fallback, so glyphs that the primary face lacks, such as arrows and symbols, come from another face. LÖVR's default font has no arrow glyphs.
- Bidirectional display, so right-to-left text renders in the correct order. Bidirectional editing remains open.
- A language tag per style, which shaping and fallback use.
- Ellipsis and a maximum line count, which cosmic-text provides together. An ellipsised text node shows its full text in a tooltip.
- Inline spans with different styles, such as emphasis, colour, or code, within one text node.

The text module uses [cosmic-text](https://github.com/pop-os/cosmic-text). [parley](https://github.com/linebender/parley) provides the same capabilities with a richer styled-span model and is the text layer of the Linebender stack. cosmic-text is used because it also provides an editor with caret and selection movement, which the text field uses, and because WayVR's wgui uses it in the same domain.

### Styles

A text node has a style from the typography scale: a role such as body, caption, label, title, or code, plus optional overrides for weight, colour, and alignment, and a language tag. Alignment is logical, `start`, `center`, or `end`. [Theming](theming.md#typography) defines the scale. Font families come from the theme. The accessibility text scale multiplies every role's size, and the host clamps every resolved size to the minimum legible size for the panel's presentation, as [Theming](theming.md#typography) describes.

### Links and rich text

A span can carry a link target. A text node publishes its link spans as items whose shape is the set of rectangles that `tree:textLayout` returns for the span's line fragments, so links are hovered, pressed, focused through traversal, and addressed in tests like any other item. Activating a link calls the node's `onLink` with the span's target.

The standard `Markdown` composite renders Markdown into text nodes, lists, code blocks, and links. A Lua parser in the standard kinds produces a tree of the document's blocks and spans, and the composite turns it into elements. It covers CommonMark's common blocks and inline spans and GitHub tables; its module comment lists what it leaves as literal text. The plugin manager shows plugin READMEs through it.

### Glyph rendering

Shaping produces glyph ids, not codepoints. LÖVR's `Font` rasterises glyphs by codepoint and `Pass:text` accepts only strings, so shaped output cannot be drawn through `Pass:text`.

The text module generates multi-channel signed distance field glyphs by glyph id in Rust, packs them into an atlas that it owns, and returns glyph quads that the host draws through the toolkit shader. The clip, surface shape, and elevation logic therefore applies to text exactly as it applies to boxes, and one atlas serves every panel. Glyph outlines come from skrifa, through the version that cosmic-text re-exports, so the build carries one copy. Distance fields are generated by the msdfgen library that LÖVR builds, which Rust links directly as `libmsdfgen` through its C interface.

Generation is bounded per frame:

- The font database is built at startup, not on the first measurement, because enumerating and parsing system fonts takes far longer than a frame.
- Glyph generation has a per-frame budget. A glyph not yet generated draws as a placeholder until it is ready, and its node's instance slots are rewritten when it is, so a window title in a script with many new glyphs does not stall a frame.
- The atlas is paged. A glyph keeps its page and coordinates for its lifetime, so instance data that refers to it stays valid as the atlas grows. Glyphs are reference-counted by the instances that draw them, not by every shaped run that contains them, so a long text that is mostly scrolled out of view holds only its visible glyphs. Only unreferenced glyphs are evicted. The atlas has a size limit. At the limit, new glyphs evict the least recently used unreferenced glyphs, and if none are unreferenced, the new glyph draws as a placeholder. A share of the atlas is reserved for the interface fonts' common glyphs, so a panel full of rare glyphs cannot leave the plugin manager drawing placeholders. Inspection reports atlas pressure.
- The atlas does not grow across source reloads. The host releases its glyph references when its contract epoch ends, including when it ends abnormally.
- The atlas pages are LÖVR textures. They are released before the Lua state closes for a restart, and recreated from the CPU-side glyph cache in the next state.

A LÖVR fork patch that rasterises and draws glyphs by id is the alternative. It would reuse LÖVR's atlas, but it would couple the toolkit to LÖVR's atlas management, including its per-glyph lookup lock, and it would leave text as the one primitive that does not go through the toolkit shader.

Multi-channel signed distance fields keep glyphs sharp across the range of distances and scales that a VR panel sees. They round sharp corners at very small sizes and cannot apply hinting. The minimum text size keeps text above the range where that matters, and the shader computes the edge width from screen-space derivatives on each axis, so edges stay antialiased at any distance and at grazing angles.

### Fonts

The toolkit ships IBM Plex Sans as the UI family and Iosevka as the monospace family, both under the SIL Open Font License, with a fallback for scripts and symbols they lack, and an icon font. Icons are glyphs in the same text path, so they wrap, align, scale, and colour with text. System fonts are available through the fallback chain. Licences and attribution are recorded in [CREDITS.md](../../../CREDITS.md) when the fonts are added.

Colour emoji have no distance field representation. A colour font with outlines, such as a COLR font, renders its outlines in a single colour. A bitmap-only colour font, such as a CBDT font, has no outlines, so its glyphs fall through to the next face in the fallback chain, or to the missing-glyph box. A bitmap glyph path is an open question.

### Text editing

The text field kind keeps the edited text, caret, and selection as node state. Caret movement, selection, and hit testing from a pointer position use the native editor, so they follow grapheme clusters and shaped positions. Multi-line text areas use the same kind with wrapping enabled.

A text-input kind declares an input hint: `text`, `multiline`, `search`, `number`, `email`, `path`, `url`, or `password`. The hint also decides the label and behaviour of the keyboard's Enter key: a new line, a search, or a submission. The focus service passes it to the virtual keyboard, which shows a matching layout, such as a numeric pad for a number field. A password field draws its text masked and is excluded from inspection's text.

Text fields accept paste through the keyboard's paste key, Ctrl-V, and the field's context menu. Read-only selectable text uses the same selection model without editing. A pointer drag selects text, and a touch selection shows handles at both ends that a fingertip drags. Copy and paste go through the session clipboard service, which is platform-neutral and has a Wayland backend that reads and offers the compositor's selection through the native API, so text copied from a toolkit panel pastes into a client window and the reverse.

## Open questions

- Bidirectional editing: caret movement through mixed-direction text, and selection rendering across direction runs.
- Input-method composition. The focus service has no preedit path.
- Whether the distance field atlas uses one em size for all text, or a small set of sizes for caption and title text.
- A bitmap glyph path for colour emoji.
- Hyphenation for long compound words in narrow columns.
- Fallback faces for the scripts that IBM Plex Sans lacks, with legible shapes at small angular sizes and a licence compatible with GPL-3.0-only redistribution.
