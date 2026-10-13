# Input

## Lua does the raycasting

Lua owns scene geometry and converts XR poses to pixel-space hits. Rust receives sink events, then resolves Wayland regions, subsurfaces, and popups. Window coordinates use logical surface units, which can differ from texture dimensions. [Compositor geometry](compositor.md#windows) owns that conversion boundary.

## Seats

Each native seat has independent pointer, keyboard focus, and key state. Pointer motion does not take keyboard focus. The default seat lives with the compositor and cannot be destroyed. Other seats withdraw their globals and send leaves when destroyed. Multiple seats are native mechanism; Lua can choose to use one. Simulating several pointers over one seat cannot provide independent state.

### Seat lifetime

Source reload holds plugin-created seats while the replacement loads. A named seat can be reclaimed once, preserving its identifier and bound Wayland objects. Handover cancels its drag, releases keys and buttons on their original clients, clears modifiers and focus, and installs the replacement layout. Unclaimed seats are destroyed even if loading fails.

The hold avoids withdrawing and readvertising globals that clients have failed to follow. It belongs in native code because old plugin owners close before the new configuration exists. Instance reload and hard restart do not hold plugin seats. Multi-seat popup and drag behavior needs toolkit validation.

## Clipboard

One designated seat bridges the host clipboard and primary selection. Other seats remain isolated. Changing the bridge applies at a frame boundary without copying an existing selection retroactively. Bridging every seat would make copies race on one host selection.

Transfers preserve MIME lists and pass file descriptors between data owners; lunette buffers no content. Superseded host offers refuse reads, unoffered types are refused, and the bridge clears only selections it published. Echo suppression relies on cancellation preceding replacement announcement; the protocols do not guarantee that order, so reversed delivery can leave stale selections.

## Keyboard and keymaps

Native sinks accept keycodes and explicit modifiers. Modifier changes do not synthesize representative key presses. Clients interpret events under the seat's XKB map and implement repeat. Keymap queries are stateless and have no compose or dead-key state. A seat carries one layout group because there is no active-group switch operation. The binary reads inherited layout settings and supplies them explicitly to native libraries.

Host keyboard delivery uploads the seat layout before keys and refuses missing seats or failed uploads. [Host input](host-desktop.md#input-injection) differs for uinput, which uses the host layout.

`sink:typeText` can temporarily upload a keymap for UTF-8 that the current map cannot express. It must not interleave with manual key events; clients process keymap changes asynchronously. Shared physical input routing instead refuses unrepresentable characters. [Shared input guarantees](../../../lua/lunette-contracts/README.md) own Lua delivery policy.

## Drag and drop

A release goes to the sink that received its press, even after hover moves. This preserves the client's implicit grab. The current hover determines the native drop target. [Compositor drag state](compositor.md#drag-and-drop) owns cancellation and icons. Host-to-lunette drag-and-drop is unsupported.

## XR backend

Input uses LÖVR's headset API. Gesture and movement policy stay in Lua; missing native capabilities belong in LÖVR rather than separate OpenXR action sets. The OpenVR backend initializes its manifest before sampling. An open dashboard suppresses buttons, axes, and scheduled haptics while retaining valid poses. Failed samples and recentring invalidate tracking; aim never substitutes for grip.

## Blocking input to the underlying application

OpenXR overlay input also reaches the application underneath. There is no standard blocking mechanism. A possible libmonado integration is runtime-specific and unimplemented. Clicking a panel can therefore also activate the underlying application. No Lua routing change closes this gap.

## Known gaps

OpenVR bindings and haptic frequency mapping need hardware acceptance. Panel interaction with both Steam Frame controllers has been observed; this does not validate other bindings or wear detection. Multi-seat popup grabs, drag ownership, and handover remain less exercised in toolkits. Only source reload preserves plugin seats.

Live checks must cover the intended controller bindings, layout and arbitrary-text behavior, clipboard ordering, drag ownership, and seat transfer with GTK and Qt clients. Automated event and geometry recorders do not establish headset presentation. Shared Lua input limits belong in [the contracts](../../../lua/lunette-contracts/README.md).
