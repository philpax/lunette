# Research

The design draws on published XR design guidance, XR interaction toolkits, UI frameworks for Lua and Luau, layout and text libraries, and other VR desktop shells. Each entry states what the system is, what the toolkit takes from it, and what it leaves out and why.

## XR design guidance

Published guidance gives the numbers behind the default tokens in [Theming](theming.md). Most of it is angular. At 1 metre, 1 degree is 17.5 millimetres, and one distance-independent millimetre (dmm) is one millimetre seen at one metre.

[Microsoft Mixed Reality design guidance](https://learn.microsoft.com/en-us/windows/mixed-reality/design/interactable-object) gives a minimum of 1 degree for hand-ray targets and 2 degrees at 45 cm for direct touch, with buttons of at least 32 mm for direct presses. Its [typography guidance](https://learn.microsoft.com/en-us/windows/mixed-reality/design/typography) gives 0.35 to 0.4 degrees as the minimum legible text height and 0.6 to 0.75 degrees as comfortable, advises against light weights at small sizes because thin strokes shimmer, and recommends at most two families. The toolkit takes the text sizes and the weight and family rules. The 1 degree ray minimum is a floor rather than a default, because other guidance asks for much larger targets.

Meta's [hand interaction guidance](https://developers.meta.com/horizon/design/hands-ui-best-practices/) asks for targets of 2.5 to 3 degrees for both poke and ray. Its [raycasting specification](https://developers.meta.com/horizon/design/raycasting_specs/) defines cursor behaviour: a constant angular cursor size, a select ring smaller than the hover ring, hover and press transition timings, and a tiebreak for surfaces within one centimetre of each other along the ray. Its [Android app requirements](https://developers.meta.com/horizon/documentation/android-apps/design-requirements) ask for 48 dp targets, 60 dp for primary controls, invisible hit slop, and light backgrounds no brighter than #DADADA. The toolkit takes the target range, the cursor behaviour, hit slop, and the rule against pure white.

[Android XR's design guidance](https://developer.android.com/design/ui/xr/guides/visual-design) defines 1 dp as 0.868 dmm, recommends 56 dp targets with 48 dp as the minimum, and defines elevation levels for orbiters, popups, and dialogs at 16, 32, and 56 dp. It advises against elevating large or scrollable areas. The toolkit takes the elevation levels for popovers and dialogs, and the rule against elevating scrollable content.

Apple's visionOS Human Interface Guidelines and the WWDC23 session [Design for spatial user interfaces](https://developer.apple.com/videos/play/wwdc2023/10076/) ask for interactive targets of at least 60 points including padding, a hover effect on every interactive element shaped like the element, and windows that keep their angular size as they move. The toolkit takes the hover rule. Window scaling with distance is the presentation scale in [Presentations](presentations.md). The conversion from points to physical size is not published, so the numbers are used only as a cross-check.

## Ray pointing research

Pressing a trigger moves the controller and the ray with it. Wolf and colleagues ([CHI 2020](https://www.uni-ulm.de/fileadmin/website_uni_ulm/iui.inst.100/institut/mitarbeiterbereiche/wolf/HeisenbergCHI20.pdf)) attribute about 30 percent of ray pointing errors to this movement and correct a quarter of them by using the target hovered just before the press. The toolkit takes press latching, hover stickiness, and filtering of the ray, as [Input](input.md#ray-robustness) describes.

## Interaction toolkits

### StereoKit

[StereoKit](https://github.com/StereoKit/StereoKit) is an open-source XR engine with an immediate-mode UI. A window is declared every frame with `UI.WindowBegin` and `UI.WindowEnd`, widgets are calls between them, and ids are hashes of an id stack combined with each widget's label. Layout is cursor-based in the manner of Dear ImGui, with `SameLine`, `LayoutReserve`, and `LayoutPushCut`, and windows size to their content using the previous frame's extent.

Its development branch models input as interactors. An interactor is a capsule, either a point such as a fingertip or a line such as a ray, with an event mask for poke, pinch, and grip, an activation type that is either a button state or a physical depth, a source mask that keeps one hand's interactors from competing, and a minimum distance that keeps far rays from acting on elements within reach. Elements register their volumes every frame, and the nearest element by priority and distance takes focus. Buttons have 10 mm of depth and activate at half of it, and pressed geometry follows the finger. Theming uses settings for margin, padding, gutter, depth, and rounding, colour categories with normal, active, and disabled states, and about 20 visual slots whose mesh, material, and sound can each be replaced. Its quadrant meshes resize like a three-dimensional nine-slice, so bevels keep their shape at any size.

The toolkit takes the interactor model, the per-source arbitration with a minimum distance for rays, physical press depth, the depth values for controls, and replaceable visual slots, which become [visuals](extension.md#visuals). It leaves out immediate mode, label-derived ids, cursor-based layout, and sizing from the previous frame. Those suit small tools but not dense interfaces with scrolling, virtualised lists, overlays, and focus traversal, and StereoKit itself has no general scroll container, no flexbox or grid, and no focus traversal beyond text input.

### Meta Interaction SDK

The [Meta Interaction SDK](https://developers.meta.com/horizon/documentation/unity/unity-isdk-poke-interaction/) pairs interactors and interactables by type: poke, ray, and grab. Both feed one pointer event stream of hover, unhover, select, unselect, move, and cancel. Interactor groups arbitrate within one hand, so that only one interactor hovers or selects at a time. Poke interaction defines a hover zone above the surface with hysteresis, a minimum activation depth, separate drag thresholds along and across the surface, a cancel distance, and a recoil assist that allows fast repeated presses. A limiter clamps the rendered hand at the surface so the finger does not appear to pass through.

The toolkit takes the near-touch parameters in [Input](input.md#near-touch), the per-hand arbitration, and the fingertip clamp. It leaves out the typed pairing of interactors and interactables, because nodes receive modality-independent events instead.

### MRTK3

[MRTK3](https://learn.microsoft.com/en-us/windows/mixed-reality/mrtk-unity/mrtk3-overview/architecture/interactors) builds on Unity's XR Interaction Toolkit. Interactables respond to generic hovered and selected states, not to interactor types. Each interactor exposes an attach transform for manipulation and a variable select progress for analog triggers and pinches. An [interaction mode manager](https://learn.microsoft.com/en-us/windows/mixed-reality/mrtk-unity/mrtk3-input/packages/input/interaction-mode-manager) enables subsets of interactors together, such as disabling rays when a hand is near a surface.

The toolkit takes modality-independent node events, select progress, the attach point, and near mode, which becomes the near-beats-far rule. The input mode service in [Presentations](presentations.md#input-modes) has the same role as the mode manager at the level of the whole session.

### visionOS input

In visionOS, the system renders gaze hover outside the application's process, and controls receive the same gestures from gaze and pinch, direct touch, and a trackpad pointer. The toolkit takes the principle that controls are written against semantic gestures. It does not take gaze as an interactor yet, as [Input](input.md#open-questions) records.

## Authoring models

[React](https://react.dev/) and its Luau port [react-lua](https://github.com/jsdotlua/react-lua) model an interface as function components that return elements, with hooks for state and effects, reconciled by key against the previous output. The toolkit takes this model, because plain Lua control flow inside a component is the easiest model for plugin authors, and because a keyed reconciler is what hand-written retained UI in Lua converges on. It leaves out react-lua itself: its fibre architecture, scheduler, and full hook set are larger than the toolkit needs, and its allocation per render is a cost in Luau.

[Vide](https://github.com/centau/vide) and [Fusion](https://github.com/dphfox/Fusion) are signal libraries for Luau. A component runs once and binds reactive closures to instance properties, so updates are precise and no diffing happens. Fusion 0.3 introduces scopes that own cleanup, which resemble the plugin runtime's owners. The toolkit takes observable stores for service state, and scoping of effects to owners. It leaves out signals as the authoring model, because conditional content and lists need special helpers and a read outside a reactive closure loses its reactivity silently. [Authoring](authoring.md#comparison-with-other-models) records the comparison.

[Iris](https://github.com/SirMallard/Iris) offers a Dear ImGui-style immediate API over retained Roblox instances, keyed by call site. [Plasma](https://github.com/matter-ecs/plasma) offers immediate-mode calls with React-like hooks. Both show that an immediate-looking API can sit on retained nodes. The toolkit takes the separation between authoring and retained nodes, which is what allows other frameworks to target the same host, as [Extension](extension.md#other-frameworks) describes.

[Stardust XR's asteroids](https://github.com/StardustXR/asteroids) is a declarative Elm-like layer: application state produces an element tree that is diffed against the previous one. It is a precedent for declarative UI in a VR shell.

## LÖVR UI libraries

[lovr-ui](https://github.com/immortalx74/lovr-ui) is an immediate-mode library for LÖVR in the style of Dear ImGui, with laser pointers, thumbstick list scrolling, and an on-screen keyboard. [chui](https://github.com/jmiskovic/chui) is a retained library with pressable three-dimensional widgets, row layout inside panels, and interaction from controllers, fingertips, or the mouse. Both show what LÖVR's drawing primitives support directly. The toolkit takes chui's pressable widgets and its use of the same widgets for touch and rays. Neither library has the layout, text, extension, or ownership model the session needs.

## Layout engines

[taffy](https://github.com/DioxusLabs/taffy) is a Rust implementation of CSS block, flexbox, and grid layout, with measure functions for leaves and a per-node cache that makes relayout incremental. It is used by Bevy, Servo, Slint, Zed, and WayVR's wgui. The toolkit uses it.

[Yoga](https://github.com/facebook/yoga) is the C++ flexbox engine behind React Native. It is mature, but it has no grid and adds a C++ build dependency to a Rust host.

[Clay](https://github.com/nicbarker/clay) is a single-header C library that lays out an immediate-mode tree redeclared every frame, with fit, grow, fixed, and percentage sizing, scroll containers, and a sorted list of render commands. It is fast, but redeclaring the tree every frame from Luau would be one native call per node per frame, and it has no grid.

[morphorm](https://github.com/vizia/morphorm) is the layout engine of the vizia toolkit, with a smaller feature set than flexbox. It offers no advantage over taffy for this use.

## Text

[cosmic-text](https://github.com/pop-os/cosmic-text) provides shaping through a Rust port of HarfBuzz, bidirectional text, font fallback, line wrapping, and an editor with caret and selection, and is used by the COSMIC desktop and WayVR's wgui. [parley](https://github.com/linebender/parley) provides shaping, fallback through fontique, and a rich styled-span model, and is the text layer of the Linebender stack. [HarfBuzz](https://harfbuzz.github.io/) is the reference shaping engine in C. The toolkit uses cosmic-text, as [Layout and text](layout-and-text.md#shaping-and-wrapping) describes.

Multi-channel signed distance field text keeps glyphs sharp across distances and scales, which suits world-space panels. LÖVR already renders text this way. Its limits are rounded corners at very small sizes and the absence of hinting, which the minimum text size in [Theming](theming.md#typography) keeps out of range.

## Other VR desktop shells

WayVR's [wgui](https://wayvr.org/docs/wgui/) is a retained-mode Vulkan GUI library built on taffy, cosmic-text, and resvg. Interfaces are declared in XML with templates, macros, and includes. Its elements are boxes, labels, rectangles, sprites, and images with flex, block, and grid attributes, and its components include buttons, sliders, checkboxes, tabs, edit boxes, radio groups, colour selectors, and tooltips. Theme colours are named tokens with opacity variants. WayVR is lunette's closest relative, and its compositor code is vendored in this repository. The toolkit takes wgui's choice of taffy and cosmic-text and its token naming approach. It leaves out XML layout, because components in Lua compose with plugin state directly, and Rust-side widgets, because widgets in lunette are plugin policy.

The [SteamVR dashboard](https://developer.valvesoftware.com/wiki/Panorama) uses Valve's Panorama framework, with XML panels, a CSS dialect, and JavaScript, rendered to overlay textures. It shows the reach of a web-like layout and styling model in VR. It renders flat textures, which the depth requirement rules out.

[Stardust XR](https://github.com/StardustXR) is a Rust VR shell whose clients connect to a server that handles input through signed distance fields. Its [molecules](https://github.com/StardustXR/molecules) library provides widgets. xrdesktop and SimulaVR present desktop windows as textured quads and have little native UI of their own.

## Rendering strategies

Rendering panels to cached textures and submitting them as [composition layers](https://developers.meta.com/horizon/documentation/native/android/os-compositor-layers/) gives the sharpest text, because the compositor resamples the image once. Drawing geometry in the scene every frame gives real depth and depth testing against hands and rays. The toolkit draws in the scene, as [Rendering](rendering.md) explains, and keeps per-panel instance buffers so that idle panels cost little CPU time.
