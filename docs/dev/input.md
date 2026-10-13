# Input

## Lua does the raycasting

The native and Lua input boundary is a pixel-space event sink. Lua owns panel poses and scene geometry, so it turns XR poses into rays, intersects those rays with surfaces, and sends pixel coordinates to the sink. Rust does not know the 3D scene. This keeps gaze, hand tracking, scripted input, and other pointer sources independent of native geometry. `@lunette-contracts/quad` supplies flat-quad intersection; the compositor hit-tests regions, subsurfaces, and popups within a surface ([Compositor](compositor.md#windows)).

A window's surface coordinates are the units used by pointer positions. They can be smaller than its texture when the client uses a buffer scale or viewport destination. Texture crop and child-surface geometry remain compositor mechanisms ([Compositor](compositor.md#windows)).

## Seats

A Wayland seat has one pointer and one keyboard. lunette supports multiple native seats, each with its own pointer position, focus, and keyboard state. Pointer motion and keyboard focus are separate: moving a sink pointer does not take keyboard focus. The host desktop has one input seat because it has one cursor ([Host desktop](host-desktop.md#the-input-domain-leak)).

The default seat lives with the compositor and cannot be destroyed. Other seats end through `seat:destroy()`, which withdraws the `wl_seat` global after sending pointer and keyboard leaves.

### Seat lifetime

A source reload holds plugin-created seats until the replacement configuration loads. A named held seat can be claimed once by `lunette.newSeat`; it keeps its identifier and bound Wayland objects. The compositor resets it for the new owner: it cancels a drag, releases keys and buttons on their original clients, clears modifiers, and withdraws pointer and keyboard focus. The replacement supplies keyboard configuration. A held seat not reclaimed is destroyed after loading succeeds or fails. Handles from before handover still name the same seat.

This hold prevents withdrawal and re-advertisement of a seat global under the same name, which clients have failed to follow. Seat handover is limited to source reload. Multi-seat behavior is less exercised by GTK and Qt, and popup-grab or drag ownership confusion remains possible.

## Clipboard

smithay stores the clipboard and primary selection per seat. The host desktop has one of each, and one designated bridge seat connects its selections to the host. Other seats remain isolated within lunette. The session's first seat is initially the bridge. Changing the bridge takes effect at the next frame boundary; a selection already held by the newly bridged seat is not copied retroactively.

The host's selections are offered to the bridge seat, and selections made there are offered to the host. A selection on another seat is offered only to clients focused on that seat. MIME types are preserved exactly, and a request for an unoffered type is refused. Transfers pass file descriptors between the owning processes; lunette does not buffer selection contents or spawn a writer per request, so a client that never reads stalls only its data owner. A host offer carries an increasing identifier, and a read for a superseded offer is refused. The bridge withdraws only selections it published, because clearing an arbitrary selection would erase data owned by a client. Host echo is suppressed while lunette owns the live source; [Known gaps](#known-gaps) records the ordering limit.

Which seat represents the desktop is Lua policy.

## Keyboard and keymaps

Wayland clients receive an xkb keymap, keycodes, and modifier state, then translate keysyms themselves. Native sinks accept keycodes and explicit modifier state; setting modifiers does not synthesize representative key presses. Modifier names are the closed `lunette.ModifierName` set. Seats expose stateless keymap queries: `symbolFor` and `characterFor` translate a keycode under modifiers, and `strokeFor` maps a keysym or character back to a keycode and modifiers. Queries support explicit modifiers, including AltGr, but have no dead-key or compose state. Physical text comes from LÖVR's committed UTF-8.

A seat carries one layout group. A configuration that names multiple layouts for one seat is refused. A second layout requires a second seat. Inherited `XKB_DEFAULT_*` settings are read by the binary and passed to the compositor; an inherited layout list is narrowed to its first entry and logged so a configuration with no explicit layout still gets a usable seat. The compositor does not read environment variables.

The seat advertises client-side repeat with a 500 ms delay and 50 repeats per second unless `newSeat` supplies `repeatDelay` or `repeatRate`. Clients implement the repeat; whether a key remains held is input-source policy. The [shared input protocol](../../lua/lunette-contracts/docs/input.md) specifies virtual and physical delivery.

A host sink reads a key or modifier change under the seat's layout, which is uploaded to the host input provider first. A seat missing from the current frame snapshot, or whose layout cannot be uploaded, has its key refused ([Host desktop](host-desktop.md#input-injection)).

### Arbitrary text entry

`sink:typeText` enters arbitrary UTF-8. The compositor resolves each run through the seat's layout, temporarily uploading a keymap and restoring the original for text the layout cannot express. The temporary map races with the client's own keymap handling, so arbitrary text entry must not interleave with manual key events. It supports clipboard-less paste, dictation, and remote typing such as `lunctl` entering a command in a terminal. Shared physical input routing does not use this fallback for native window text; it refuses a character the seat keymap cannot represent ([Input](../../lua/lunette-contracts/docs/input.md#virtual-activations-and-committed-text)).

## Drag and drop

A native drag starts from a press and is carried by the seat pointer. Lua moves that pointer as it routes hover. A press is accepted on the sink under the pointer; its release is sent to the sink that received the press even if the pointer has since moved elsewhere. This preserves the client's implicit grab and lets the drag end. The drop target is the window under the pointer at release, or no window. [Compositor drag and drop](compositor.md#drag-and-drop) specifies the native state; icon drawing is [laser policy](../../lua/lunette-plugins/laser/docs/aim-and-drag-feedback.md).

Host-to-lunette drag-and-drop has no protocol. Drag-and-drop inside lunette works.

## XR backend

lunette uses LÖVR's `lovr.headset` input for poses, buttons, axes, and haptics. Gesture recognition and movement policy run in Lua. lunette creates no OpenXR action sets outside LÖVR. That would require LÖVR to expose its instance and session and allow lunette to join its once-per-session attach call for custom binding names. An input capability needed by lunette but absent from LÖVR is added to LÖVR instead.

The OpenVR backend initializes its action manifest before polling events or updating actions, then samples head and hand actions once per accepted frame. An open SteamVR dashboard clears buttons, touches, axes, and scheduled haptics while retaining valid poses; input resumes on the next sample after it closes. Failed samples and recentring invalidate tracking. Grip and aim remain distinct, and aim is not substituted for grip. This backend does not expose touch grip poses, hand tracking, skeletons, or controller models ([LÖVR integration](lovr-integration.md#backend-selection)).

Haptics use `lovr.headset.vibrate`. OpenVR schedules pulses up to 20 ms, and a frequency of zero selects 120 Hz.

## Blocking input to the underlying application

With `XR_EXTX_overlay`, controller input reaches both the overlay and the application underneath. OpenXR has no standard mechanism to block that input. WayVR uses libmonado's `BlockFlags` through Monado API 1.6 and later. A proposed `lunette.setGameInputBlocked(inputs, poses)` would detect libmonado at runtime and return false on other runtimes. Neither this mechanism nor input-blocking policy is implemented. Clicking a panel can therefore also reach the underlying application on every runtime.

## Decisions

Seats are multiple by default. Collapsing them to one is a small Lua change; faking multiple seats over one, as WayVR does, cannot provide independent pointer and keyboard state.

The seat hold is native mechanism because the plugin runtime closes every owner before the replacement exists, so a plugin cannot transfer a seat to a configuration that has not run. Keeping seats in module state was rejected because module bodies run again on reload. Resetting the held seat prevents a new owner inheriting input that the old owner cannot release.

A seat carries one layout group because no API operation can change the active group. Modeling a switchable group would allow reported key translations to drift from the layout clients actually use.

Bridging every seat would make rapid copies race on one host clipboard and expose the same host selection through every seat.

## Known gaps

Host clipboard echo suppression assumes cancellation precedes a replacement announcement. The protocols do not guarantee that order; reversed delivery can leave a stale internal selection. Marking offers with a nonce MIME type was rejected because it would change the re-offered MIME list.

OpenVR controller bindings and haptic frequency mapping need SteamVR hardware validation. Steam Frame controller poses and buttons are bound, and panel interaction has been observed with both controllers. HMD activity is inferred from use rather than wear detection.

Input blocking is unimplemented and the specified mechanism is Monado-only. Multi-seat popup grabs and drag-and-drop ownership remain less exercised in toolkits.

Only source reload holds seats. Plugin-instance reload and hard restart destroy plugin seats, so clients that outlive either must move to the newly created seats. Seat handover has Lua-side and compositor tests with an in-process client; GTK4 behavior across handover has been reproduced only in a live session.

Shared virtual-input and local-receiver limitations are in [Input](../../lua/lunette-contracts/docs/input.md#known-gaps).
