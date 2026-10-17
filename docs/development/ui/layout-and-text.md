# Layout and text

## Units and coordinates

Layout uses metres from a panel's top-left corner, with x right and y down. Elevation points towards the viewer. Drawing, input, and inspection use the same coordinates. The host handles the change to scene coordinates, so a kind or consumer does not independently invert text or pointer positions.

Depth is separate from layout. [Spatial model](spatial-model.md) states the current panel and node geometry, and [Theming](theming.md#units) records why physical units matter.

## Layout model

The native layout implementation uses [taffy](https://github.com/DioxusLabs/taffy). Its rounding pass is disabled because rounding authored metres to whole units would collapse ordinary controls. Flexbox and grid stay native because intrinsic sizing, percentage resolution, and minimum-size interactions have a long correctness tail. The exact dependency version belongs to Cargo, and the [generated native declarations](../../../lua/lunette/init.luau) own supported styles.

Host kinds choose container layout with a style or native text measurement. A style-sized box uses container layout even when it has no children. Native descriptor leaves and native callbacks are separate mechanisms; they are not additional host kind registrations.

Theme-dependent sizes resolve before layout. Changes to spacing or text scale can change geometry, so fixed-size panels need wrapping or scrolling rather than assumptions about one theme's dimensions.

## Panel sizing

Panels have fixed or content sizing. A fixed panel lays out within its supplied dimensions. A content-sized panel uses its measured content, subject to the supplied bounds. The [host contract](../../../lua/lunette-contracts/ui-host.luau) owns the options and size-update semantics.

Content sizing updates during commit. It does not wait for a capture to end and has no capture-delay timeout. Relayout preserves capture, but there is no frozen drag-layout frame or oscillating-size guard. A control whose own input changes surrounding geometry must account for that movement.

## Scrolling

The host clips scrolling content and keeps offsets in node state. A relayout clamps offsets to the current content. Node handles support programmatic scrolling, and traversal brings focused content into view. Scroll events carry the pointer's local position so a consumer can interpret them relative to the target.

The [standard kinds guide](../../../lua/lunette-plugins/ui/standard/README.md) owns collection and scroll-control behavior. A collection API does not imply host mount points for virtualised items, retention of offscreen captures, estimated-size correction, or a frame materialisation budget. Those mechanisms are not exposed by the current mount contract.

## Scripted layout

The native layout tree supports measured leaves and scripted containers. The host does not expose either through kind registration and calls layout computation without a script dispatcher. A radial layout registered as a host kind therefore cannot use the native callback mechanism through that registration.

Native callers supply callbacks to the layout computation. Within a scripted callback, `context.measure(child, width, height)` measures a child against separate available-space values. It is a plain function call, not `context:measure` and not a table of dimensions. The [generated native declarations](../../../lua/lunette/init.luau) and [native callback tests](../../../crates/lunette/src/lua/tests/layout.rs) own the full callback shape.

The callback context is scoped to the computation. It cannot be retained for later use. Script failures are returned with layout results, and callbacks cannot re-enter the tree through its ordinary methods while it is borrowed. These constraints keep native layout coherent across Lua callbacks; they do not establish a host-side layout-phase callback API.

## Native binding

The host owns a native layout tree per panel and sends pending changes in a batch. Computation returns changed placements rather than requiring a separate userdata or table read for each node. Batching matters because native result tables and userdata allocate.

The native tree uses taffy's low-level layout interface to support text, descriptor leaves, and callbacks alongside container layout. That dependency boundary requires review when taffy's API changes. Signatures, operations, and result layouts belong to the generated declarations rather than a copied inventory here.

## Text

### Shaping and wrapping

Text is shaped, wrapped, and measured natively through [cosmic-text](https://github.com/pop-os/cosmic-text). LÖVR's string-oriented text path cannot preserve shaped glyph ids and positions, so toolkit text uses its own layout and glyph drawing path. Font fallback supplies glyphs absent from the primary face. Shaped display does not imply support for bidirectional editing or input-method composition.

cosmic-text provides an editor as well as shaping, but the toolkit does not use that editor for its text fields. The choice of shaping library does not make native caret or selection behavior part of the host contract. [Research](research.md#text) compares the alternatives.

### Styles

Text styles resolve from theme typography with supported per-node overrides. Accessibility text scale changes resolved sizes and can trigger layout. The [theme contract](../../../lua/lunette-contracts/theme.luau) and generated native declarations own the supported style fields. The host does not enforce a presentation-dependent angular minimum text size.

### Links and rich text

The standard Markdown view composes toolkit elements rather than embedding an external renderer. Its checked implementation owns supported syntax. The host does not expose addressable link-span items or a general item-shape registry, so a shaped text run alone does not give each span independent hover, focus, and inspection identity.

### Glyph rendering

Shaping produces glyph ids rather than codepoints. The native glyph atlas generates multi-channel signed distance fields by glyph id with msdfgen, and the host draws them at their shaped positions. Text therefore follows the toolkit's clipping, curve, elevation, and opacity path rather than a separate `Pass:text` path.

Glyph fields are generated on workers on first demand. An unready glyph draws nothing until its field is available. New text can fill in over several frames instead of blocking the frame on all glyphs. The font database is also created on first use; startup does not prebuild or prewarm it.

The atlas has a fixed page limit. At capacity it can clear the least recently drawn page only after that page has been idle long enough. Clearing invalidates its glyph placements, which are generated again on demand. If every page is recent, a new glyph reports pressure and draws nothing. Glyphs are not reference-counted, and there is no reservation for common interface glyphs.

Fonts and the native atlas are shared within one Lua state and survive source reload in that state. They are not an owner-scoped cache and are not preserved across replacement Lua states. GPU textures acquired by the host are released with its runtime resources.

Distance fields retain sharp edges across viewing distances and scales, but cannot apply hinting and can round corners at very small sizes. Legible text sizes remain an authoring and theme constraint rather than a guarantee that every headset resolves the text.

### Fonts

The standard interface uses bundled UI and monospace faces with system fallback. Font files and attribution belong to [CREDITS.md](../../../CREDITS.md).

A caller loads additional font bytes with native `lunette.loadLayoutFont(bytes)`. Repeated loading of identical bytes is idempotent. Loaded faces remain available for the Lua state's lifetime, including source reload; there is no owner-scoped registration or removal. The UI host has no font-registration method.

Variable faces use their default instance. Colour outlines render in one colour through the distance-field path. Bitmap-only glyphs require fallback or a missing-glyph representation; colour emoji need a separate rendering path.

### Text editing

Text fields retain a single-line UTF-8 draft, caret, and selection in Lua node state. Native `textBoundaries` provides stateless extended-grapheme segmentation. Luau performs insertion, deletion, and movement at those boundaries and maps pointer positions using shaped glyph positions. This is not a native editor or complete visual caret navigation for complex scripts.

A value set through props does not emit `onChange`. Clipboard and focus routing remain service boundaries. The [shared panel and UI guarantees](../../../lua/lunette-contracts/panels-and-ui.md) state the supported editing contract.

## Open questions

- Bidirectional caret movement and selection across direction runs.
- Input-method preedit and composition.
- Multi-line editing and touch selection handles.
- A colour bitmap glyph path.
- Hyphenation and redistributable fallback coverage for scripts absent from the bundled faces.
- Atlas pressure that prevents new interface glyphs from drawing.
