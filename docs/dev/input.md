# Input

## Lua does the raycasting

The chain from controller to application runs from XR pose, to ray, to intersected geometry, to surface-local UV coordinates, to pixel coordinates, to a client event. The native and Lua layers are separated at pixel coordinates.

The native layer's primitive is a pixel-space event sink. The Rust code has no knowledge of the 3D scene.

```lua
local hit = ray:intersectPlane(panel.pose, panel.size)
if hit then
  local x, y = panel:uvToPixels(hit.u, hit.v)
  win.sink:pointer(x, y)
  win.sink:button('left', trigger_pressed)
end
```

Lua already has the poses, since it placed the panels, and it has access to LÖVR's maths library, its physics engine, and its shaders. Performing the intersection in the native layer would require Rust to know about panel geometry. This is the special-casing the architecture avoids, and it would limit intersection to shapes the native layer knows about.

This design permits varied input methods without native-layer changes. A ball bouncing between windows, where each impact registers as a click, is a physics callback that computes pixel coordinates. Gaze-driven input, hand tracking, a scripted demo, and a mouse in the desktop simulator work the same way: each is Lua code producing a different pair of numbers.

The standard library ships a standard quad intersection so that scripts do not need to reimplement it.

Within a surface, the native layer owns hit-testing: input regions, subsurfaces, and popups. See [Compositor](compositor.md#windows).

## Seats

A `wl_seat` has exactly one pointer and one keyboard. Multiple simultaneous cursors require multiple seats. The Wayland protocol provides no other mechanism for this.

WayVR sidesteps this with a single seat, where the pointer last used to click takes precedence. As a result, pointing the off hand at a window steals hover from the main hand. Two-handed interaction, such as dragging a slider with one hand while scrolling with the other, cannot be expressed.

Seats are a native primitive that Lua creates:

```lua
local left  = lunette.newSeat('left')
local right = lunette.newSeat('right')
```

Each seat has independent pointer position, focus, and keyboard state. Hover and focus are separate requests: `sink:pointer` and `sink:leave` move the pointer, and `seat:setFocus` gives the keyboard. Nothing derives one from the other, so a hand pointing at a panel does not take the keyboard from the other hand. The standard library creates one seat per pointing device by default, and provides a collapse-to-one-seat mode for applications that misbehave with multiple seats. WayVR is limited to faking multi-seat behaviour on top of one seat; collapsing multi-seat down to one seat requires a small amount of Lua code.

Seats are inexpensive in smithay, which is designed to support them. The cost is that popup grabs and drag-and-drop are per-seat, and multi-seat operation is less exercised in GTK and Qt, so toolkit confusion about which seat owns a grab can occur.

The host input domain is always exactly one seat, because the host desktop has one cursor. See [Host desktop](host-desktop.md#the-input-domain-leak).

## Clipboard

Each seat owns a clipboard and a primary selection, because smithay stores both against the seat and every protocol entry point takes one. The host desktop owns exactly one of each. The two do not line up, and the mapping is a designated bridge seat: exactly one seat's selections are the host's, in both directions, and every other seat keeps selections that stay inside lunette.

```lua
lunette.seats()[1].clipboardBridge   -- whether this seat's selections are the host's.
seat:setClipboardBridge(true)        -- makes them; takes the bridge off whichever seat had it.
seat:setClipboardBridge(false)       -- leaves no seat bridged, if this one held it.
```

A selection the host sets is offered to the bridge seat. A selection set on the bridge seat is pushed to the host. A selection set on any other seat is offered to the clients that seat is focused on and goes no further. The seat every session starts with is the bridged one, so a configuration that never mentions the clipboard gets the behaviour a single-seat compositor has.

Which seat is bridged is Lua's decision, like every other policy. The change takes effect at the next frame boundary, as every other mutation does. A selection the newly bridged seat already held is not pushed retroactively: only a selection lunette owns can be re-advertised, and one a client owns cannot be without asking that client for a MIME list the protocol does not expose. The next copy on the seat crosses.

MIME types are re-offered exactly as the source advertised them, in both directions; a request for a type an offer does not carry is refused rather than answered with the nearest thing. A transfer is a file descriptor passed between the two processes that own the bytes, so lunette buffers nothing and blocks nowhere. [Decisions](#decisions) below records both.

## Keyboard

Wayland clients want an xkb keymap plus raw keycodes and modifier state; they do their own keysym translation.

The native layer provides keycodes plus xkb data:

- `sink:key(keycode, pressed)` and explicit modifier state, as `sink:modifiers` or `seat:setModifiers`. The state is set directly rather than synthesised as presses of a representative key per modifier, so a client that queries it is not misled and no key event is produced that nothing asked for.
- The loaded keymap, exposed for querying: `seat:symbolFor` and `seat:characterFor` are keysym-and-text-for-keycode-under-modifiers, `seat.layouts` is the layout list, and `seat:strokeFor` is the reverse `keysym → (keycode, modifiers)` lookup.

A seat carries one layout group. Every query answers for it, and there is no way to read or set an active group, so a seat compiled with several layouts is refused rather than answered for the first. Two layouts mean two seats. [Decisions](#decisions) below records why.

Scrolling is `sink:scroll` for a continuous distance and `sink:scrollDiscrete` for whole wheel notches. The two stay apart because a client uses the difference to decide whether to scroll kinetically, and collapsing them loses that.

[The Lua API](lua-api.md#seats) is where each of these is specified.

This is sufficient for Lua to draw a virtual keyboard with correct legends, handle dead keys and AltGr, and implement key repeat, without the native layer deciding anything about UI. `xkbcommon` is already a WayVR dependency.

Key repeat is implemented in Lua. It is timing policy, it should differ per input device, and it requires a small amount of code.

### `sink:typeText(utf8)`

This is an escape hatch and is explicitly stateful. Typing arbitrary text that the active layout cannot express requires generating and uploading a temporary keymap. This technique cannot be implemented in Lua, and is subject to a race with the client's own keymap handling. Documentation states that it must not be interleaved with manual key events.

It is needed for clipboard-less paste, voice dictation, and remote control, for example `lunctl` instructing a terminal to run a command.

## XR input

lunette uses LÖVR's input API. `lovr.headset` provides poses, buttons, axes, and haptics; tracking extensions and controller models depend on the selected backend's capabilities.

The private OpenVR backend initializes its installed action manifest before event polling or action updates. It samples head tracking and hand actions once per accepted frame, using the same origin and relative prediction, regardless of input focus. Loss of input availability or an application pause clears buttons, touches, axes, and scheduled haptics, but preserves valid pose actions and velocities. Interaction getters and haptic requests remain suppressed until focus returns; cleared interaction resumes only with a new frame sample. Failed samples and recenter events invalidate tracking. The backend neither raises action-set priority nor substitutes raw controller tracking for pose actions. Grip and aim remain distinct. Touch grip poses are unavailable until their binding transform is verified; aim is not substituted for grip. Hand tracking, skeletons, and controller models remain unsupported in this backend. Native selection and lunette integration are implemented; the selection contract appears in [LÖVR integration](lovr-integration.md#backend-selection). Hardware binding acceptance remains unverified.

Gesture recognition, such as double-tap to show or hide, laser modes, and grab-to-move, is Lua timing logic layered over LÖVR's state. This is also where such tuning is expected to occur.

lunette does not create action sets outside LÖVR. For OpenXR, it does not create its own action sets. Doing so would require patching LÖVR to expose the `XrInstance` and `XrSession`, and injecting into its once-per-session attach call, for the marginal gain of custom binding names in the runtime's UI. If LÖVR does not provide an input that lunette needs, the preferred fix is to add it to LÖVR.

## Blocking input to the underlying application

With `XR_EXTX_overlay`, controller input reaches the application underneath the overlay as well as the overlay itself. Clicking a panel also triggers actions in the underlying application, such as firing a weapon in a game. OpenXR provides no standard mechanism to prevent this.

WayVR addresses this with libmonado (WayVR upstream: `src/backend/openxr/blocker.rs`), using `BlockFlags` on Monado API version 1.6 and later, blocking inputs and poses separately, gated by a config switch. lunette takes the same approach.

- `lunette.setGameInputBlocked(inputs, poses)` is the mechanism.
- libmonado is an optional, runtime-detected dependency. On a non-Monado runtime, the call returns `false` and Lua handles the degraded case. lunette does not hard-depend on Monado.
- Blocking policy is decided in Lua. The standard library's default rule matches WayVR's: block while a laser is hovering a panel. Because this is policy, it is implemented in Lua rather than in the native layer.

Haptics use `lovr.headset.vibrate`. No new API is added for this. The private OpenVR backend schedules immediate pulses of at most 20 milliseconds. Cancellation stops future pulses but cannot revoke one already accepted by the runtime. Frequency zero selects a nominal 120 Hz, not an SDK-defined default.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

Multi-seat by default, collapsible to one. Faking multi-seat over a single seat is the position WayVR is in; collapsing multi-seat to one seat is a small change.

A selection transfer passes the descriptor rather than copying the bytes. lunette never buffers a clipboard's content and never reads or writes a selection pipe. A lunette client pasting supplies a pipe to `wl_data_offer.receive`; smithay hands that descriptor to `SelectionHandler::send_selection`, and it is forwarded unread to `ext_data_control_offer_v1.receive` on the host connection, so the host's own clipboard owner writes into the lunette client's pipe. The host pasting supplies a pipe to lunette's data-control source; the descriptor crosses back to the compositor thread and is handed to `request_data_device_client_selection`, so the lunette client that owns the data writes into the host's pipe. The alternative is what WayVR does (`comp.rs:365-383`): read the bytes, hold them, and spawn a detached thread per request to write them out, with no join, no bound, and no cancellation, so a client requesting the selection in a loop spawns threads without limit. Passing the descriptor removes the whole class of problem rather than bounding it — there is no buffer to size, no worker to schedule, and a client that never reads its pipe stalls only the process that owns the data, exactly as it would with no lunette in the middle. It also removes format negotiation: the MIME list is re-offered exactly as the source advertised it, in both directions, so nothing is substituted and nothing is dropped, and a request for a type the offer does not carry is refused rather than answered with the nearest thing. The cost is that the two ends must both be alive for a transfer to complete, which is already true of any Wayland selection, and that a stale `wl_data_offer` has to be distinguished from a current one: each announcement from the host carries a strictly increasing identifier, and a read quoting a superseded one is refused rather than answered with what the user copied afterwards.

One designated bridge seat for the host clipboard, rather than last writer wins. With one seat per hand, each seat owns a clipboard and a primary selection while the host owns exactly one of each. Letting every seat write the host's clipboard means two hands copying in quick succession race, and which one the host ends up holding depends on the order two commands reach the compositor thread — timing the user cannot see and cannot control, producing a paste of the wrong thing with no way to tell why. Reading is worse: every seat would be offered the same host selection, so the two hands would silently share a clipboard that the rest of the model says is per-seat. One seat is therefore bridged in both directions and the others keep selections that stay inside lunette, which is the arrangement a user can predict — the bridged hand is the one that talks to the desktop. The default is the seat every session starts with, so a configuration that never mentions the clipboard behaves as a single-seat compositor does, and `seat:setClipboardBridge` moves it because which hand is the desktop's is policy. The alternative considered and not taken was merging the two: bridging every seat's clipboard onto the host and reflecting the host's onto all of them. That is last writer wins with extra steps, and it also makes a seat's clipboard change under it because another hand copied.

One layout group per seat, and a configuration naming more than one is refused. Every keymap query in the compositor resolves against layout group zero, and nothing in the API carries a group: `seat:strokeFor` answers with a keycode and modifiers, and `sink:key` takes a keycode. smithay's own keyboard state does track a group and applies layout-switch actions from the keymap, so a seat compiled with `us,de` and `grp:alt_shift_toggle` would have every answer silently drift the moment the user toggled — `sink:typeText('yz')` would emit the keycodes that spell `zy`. The choices were to model the group throughout, threading it through the snapshot, the query signatures, and the typing planner, and to read it back from `KeyboardHandle::with_xkb_state`; or to refuse the configuration. Refusing was taken, because there is no way to *set* the group either, so modelling it would add a parameter nothing could yet control. Lifting it means adding the group to `SeatSnapshot`, to every `Keymap` query, and to `type_text::plan`, plus a way for Lua to read and set it. A configuration wanting a second layout today creates a second seat.

The refusal applies only to a layout a configuration named. A desktop's own default reaches lunette through `XKB_DEFAULT_LAYOUT`, and naming several layouts there is ordinary: NixOS writes the list from `services.xserver.xkb.layout`, and sway and Hyprland export it the same way. Refusing an inherited list would take away the seat of a user who wrote no layout line at all, and a session with no seat has no keyboard, no pointer, and no clipboard. An inherited list is therefore narrowed to its first entry, with the matching variant, and the narrowing is logged with the advice that a second layout wants a second seat. The five `XKB_DEFAULT_*` variables are read by the binary and passed to the compositor as `KeymapDefaults`, rather than left to libxkbcommon to resolve from an empty name. That is what makes the narrowing possible: libxkbcommon offers no way to ask a compiled keymap which RMLVO layout produced it, so a keymap compiled from an empty name cannot be cut down afterwards. It also keeps the compositor crate free of environment reads, so a test states the inherited default rather than depending on the machine it runs on.

The host clipboard's echo is suppressed by ownership, and the suppression is logged. Publishing a selection to the host makes the host announce that selection back on lunette's own data-control device, because a data-control device sees every selection including the ones it set. Re-offering it would replace the lunette client's source with a proxy of itself, so an announcement arriving while lunette owns a live source for that kind is discarded. That rests on the host cancelling a source before announcing the one that replaced it, which is what smithay and wlroots both do and what neither `ext-data-control-v1` nor `zwlr-data-control-v1` states. A host that announced first would have a genuine selection discarded, and lunette's clients would keep pasting the previous one until the next copy — silent, sticky, and indistinguishable from a broken bridge. The alternative considered was a nonce MIME type appended to what lunette publishes, which an echo would carry back and a genuine selection could not. It was not taken because it gives up the property that lunette re-offers a source's own list unchanged, which is the same property that makes the rest of the clipboard path free of substitution. What was taken instead is a warning on every discard, naming the MIME list, so a gate on a real desktop can tell a compositor that announces out of order from a bridge that is broken.

Only a selection lunette owns is ever withdrawn or cleared. `set_selection(null)` is not "stop offering mine" in either data-control protocol: wlroots passes the null straight to `wlr_seat_request_set_selection` and smithay does the same, so it unsets the seat's selection whoever owns it. Sending one while the user's own copy sits on the host clipboard would empty their desktop's clipboard, on an operation both documents describe as safe to call freely. So the bridge records which selections lunette published and withdraws only those, and the compositor clears a seat's selection only when `current_data_device_selection_userdata` reports it as compositor-owned — which is exactly "lunette put this here from the host". A selection a lunette client set is that client's, and moving or removing the bridge is not a reason to destroy it.

## Known gaps

Named, not solved.

The private OpenVR controller bindings and haptic frequency mapping require SteamVR hardware validation. Deterministic action tests do not establish runtime binding acceptance. Touch grip poses, hand skeletons, and controller models remain unavailable. Steam Frame controller poses and buttons are bound, and hardware observation confirms panel interaction with both controllers. HMD activity is an in-use inference, not verified wear detection.

Host-to-lunette drag-and-drop. No protocol exists for a drag crossing a compositor boundary. In-compositor drag-and-drop works.

Input blocking is Monado-only. `libmonado`'s `BlockFlags` has no OpenXR-standard equivalent. On other runtimes, clicking a panel also reaches the application underneath.

Multi-seat is less-travelled ground. Toolkit bugs around popup grabs and drag-and-drop ownership are expected.
