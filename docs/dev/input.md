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

These stateless queries supply virtual-keyboard legends and single-key translation under explicit modifiers, including AltGr. They do not retain dead-key or compose state and cannot produce composed text from a sequence of activations. Physical text uses LÖVR's committed UTF-8 instead of reconstructing text from keycodes. `xkbcommon` is already a WayVR dependency.

Key repeat is implemented in Lua. It is timing policy, it should differ per input device, and it requires a small amount of code.

### `sink:typeText(utf8)`

This is an escape hatch and is explicitly stateful. Typing arbitrary text that the active layout cannot express requires generating and uploading a temporary keymap. This technique cannot be implemented in Lua, and is subject to a race with the client's own keymap handling. Documentation states that it must not be interleaved with manual key events.

It is needed for clipboard-less paste, voice dictation, and remote control, for example `lunctl` instructing a terminal to run a command.

## Keyboard routing

The `lunette/focus` schema 2 contract selects one current keyboard route. A route is either a native sink with an optional seat or a local Lua receiver with key and text callbacks. A registered target belongs to its caller's owner. Its handle focuses, blurs, or destroys that target. Blurring or destroying the current target leaves no route; it never restores an older target. Pointer hover remains independent of this route.

Native seat authority is separate from the current route. A native window target acquires its seat's keyboard with `seat:setFocus(sink)` before any modifier or key request. Moving to another native seat preserves the earlier seat's focus until its owning target withdraws it. A later target on the same seat replaces that authority, so destroying the older target cannot clear the newer focus. Entering a local route withdraws the previous route's native window authority. A host target changes only the Lua route: the host compositor owns its keyboard focus, and routing to it never calls `seat:setFocus`.

An omitted native seat means `lunette.defaultSeat()`, not the first entry of `lunette.seats()`. The accessor returns nil when the default seat is absent from the current snapshot. Authority and target comparisons use stable seat, window, and monitor identifiers rather than Lua wrapper identity. Native delivery retains the omitted seat as nil in sink calls, so the native default-seat convention still applies. Native window text resolves strokes against that same default seat.

An owner creates an input source through `focus:newSource`. Each operation selects one target and retains its identity and route revision until delivery ends. A source may supply a native-only target callback, including the keyboard's `Options.target` adapter. That callback is subordinate to a focused local receiver and is not called while one is current. Re-entrant delivery on the same source is refused. A route change during a callback stops later work in the operation; input never continues on the replacement route.

A delivery result is `consumed`, `unhandled`, `refused` with a message, or `failed` with a message. `unhandled` permits no forwarding to another target. A local receiver that declines a key can receive printable text from that same virtual activation under the rules below; it does not send the key to a native client. Callback errors are reported through `lunette.reportError` with source and receiver ownership context, and return `failed`. Native refusal returns `refused`. A result is not a transaction: a multi-character native operation can deliver a prefix before a later character is refused.

Every native stroke attempts its registered key release and modifier clear on the original sink and seat, in reverse order. The source records each inverse before the corresponding mutation, so a refusal or exception still attempts cleanup. A refused or raising inverse blocks subsequent delivery from that source because native state can no longer be assumed released. Reset, route loss, and source disposal attempt retained inverses; they never redirect them to the current target. Owner cleanup failure follows the plugin runtime's inverse and quarantine rules.

### Virtual activations and committed text

A virtual source delivers evdev activations with explicit modifiers, not a held-key stream. A local receiver gets the key first. If it declines the key and the route is unchanged, the source may translate it into one printable Unicode scalar for the same receiver. Control, Alt, and Logo command chords never receive this implicit text fallback. C0 and C1 control characters are not printable fallback. Right Alt is AltGr, represented by `mod5`, and remains distinct from command Alt. Explicit `source:text` is committed UTF-8 and is a separate operation.

The live keymap seat for local virtual translation is the receiver's explicit live `keymapSeat`, then the most recently selected live native seat, then the first live seat in the native list. The virtual keyboard uses that same selection and its current modifiers for legends. It does not cache a keymap from construction. Without a live keymap seat, it cannot translate a virtual key into text. This path has no dead-key or compose state, IME, or preedit.

The keyboard clears latched and locked modifiers immediately when the route changes, when it hides, and when it is destroyed. A non-modifier activation consumes the latches before receiver code runs. A route-changing callback cannot carry a pending modifier set into the replacement route. Native modifier cleanup remains on the original sink.

A physical source keeps keys and committed text separate. A local receiver gets physical key activations without keycode-to-text fallback and receives the full committed UTF-8 string through its text callback. For native delivery, printable physical keys wait for committed text unless they are command chords, avoiding a second character from the key and text streams. Native window text resolves each scalar through the selected seat's `strokeFor`; an unrepresentable scalar is refused rather than entered through an implicit temporary keymap. The native `sink:typeText` escape hatch remains a separate API.

### Physical input batches

The `lunette/frame` schema 2 contract opens an input batch before each update's handlers. The first key or text callback opens a batch if no update has opened one. Callbacks until the next update share its identifier. Owner-scoped `onBatch` observers run before update, binding, and delivery handlers, and immediately receive the current batch when registered while one exists. A physical source begins its batch there, before a binding can change the route.

A physical batch records the route revision at its start. Any route transition, including an A-to-B-to-A transition, invalidates all remaining committed text in that batch. A binding-phase key handler that consumes a key blocks all remaining text in the same batch, even when the route does not change. The frame provider publishes `textBlocked=true` to batch observers before another physical callback. The physical delivery consumer records command and consumed, failed, or refused key results through `frame:blockText`, rather than retaining rejection only in its source. A command-modified physical activation blocks subsequent committed text in its batch even if the modifier is released before text dispatch. Releasing the physical source also blocks its pending batch; recovery cannot reopen it with a new route snapshot. Replacement consumers receive the blocked metadata immediately. A failed or refused physical text result also persists invalidation. Third-party consumers of physical focus sources use the same frame operation on source release and rejected results; replacing a source does not authorize remaining text from its old batch. An unhandled local key leaves committed text eligible. A raising binding handler reports its error and continues dispatch without marking the batch blocked. Old, absent, or invalidated text batches are refused. Text eligibility returns only when the next update opens a batch. Invalidating text does not suppress later key activations in the same batch.

### Physical keypad modes

The GLFW key callback supplies an immutable snapshot of held Shift, Control, Alt, and Super and enabled CapsLock and NumLock. The frame provider carries this event-time snapshot separately from the destination seat's modifier-name list. Reading `lovr.system.isKeyDown('numlock')` only observes a held key; it does not observe the enabled lock. The virtual seat's keymap and modifier state do not describe the physical keyboard. The snapshot combines left and right Alt. The physical delivery adapter retains the sided held-key query to distinguish plain Alt from `mod5`/AltGr; that distinction can differ from event time if Alt changes before queued input is dispatched.

Native keypad digit and decimal routing uses the supplied lock snapshot for ordinary PC keypad behavior. NumLock on without Shift selects numeric input; NumLock off or Shift with NumLock selects navigation. Numeric activations use committed text only; navigation activations use mapped native keycodes and the event's modifiers. A missing snapshot cannot distinguish these cases and is refused rather than guessing from the scancode, key label, virtual seat, or a later text callback. Command chords retain one mapped activation. Local receivers still receive the complete mapped activation vocabulary and committed text separately.

The snapshot does not expose the host keysym or arbitrary layout remappings. Keypad policies outside ordinary PC NumLock/Shift behavior require a richer host input mechanism. Backends without a reliable modifier snapshot report it unavailable. Actual hardware lock acquisition remains part of manual host-desktop acceptance.

## Surface pointer input

The `lunette/interaction` schema 2 contract separates hover from a captured gesture. A surface can define `onPointer(event)` and an optional `project(origin, direction)` method through `@lunette-contracts/surface`. A protocol surface receives `enter`, `move`, `leave`, `press`, `release`, `scroll`, and `cancel` events instead of the legacy hover, leave, press, and release callbacks. Native sink delivery remains separate. A surface with a native sink receives native motion, buttons, and scroll rather than duplicate Lua pointer input. A legacy-only external surface retains its existing callbacks, including its release callback during withdrawal. That fallback cannot distinguish cancellation from release; an activating control requires the explicit pointer event protocol.

An event carries the actual pointer handle, surface-local `x` and `y` when available, and `captured` and `inside` flags. Press and release identify the pointer button. A captured move identifies its button; ordinary hover movement has no button. Scroll carries `dx` and `dy` after the pointer's dead zone, frame time, scale, and vertical inversion have applied once. Cancellation carries its button and a closed reason. Events are readonly snapshots; they expose no mutable gesture state.

Capture belongs to one pointer and button. A press records its surface before invoking that surface. Later captured movement and release reach that original surface even while another surface is hovered. Hover leave does not terminate capture. `raycast` supplies bounded hit coordinates for ordinary picking. `project` supplies unbounded coordinates for captured movement outside those bounds. A surface without projection can receive a captured event with unavailable coordinates. `quad.project` intersects a flat plane without clipping, and `quad.hit` applies the quad bounds to that result. Both reject nonfinite rays or dimensions, nonpositive dimensions, parallel or behind-origin intersections, and unusable pose inversions. Their distance is the positive ray parameter; interaction normalizes the direction before invoking surface geometry. Backface intersection requires explicit opt-in in the quad descriptor. Surface-local coordinates use the same top-left convention as ordinary hits.

Tracking loss, pointer destruction, a dead or withdrawn surface, provider replacement, a panel hide, control removal or disable, and a panel grab cancel a gesture. Owner disposal reports `pointer-destroyed`; this includes dependent-owner cleanup before a provider ends. `provider-replaced` identifies any remaining pointer ended by an inactive provider's cleanup. Cancellation never becomes an activating release. `pointer:cancel(surface, reason)` ends that pointer's gestures on the specified surface, so a panel can cancel immediately when its visibility or controls change. A grip that begins a spatial grab cancels Lua captures before the surface moves. Native pressed sinks still receive their button-up inverses. State clears before callbacks, every cancellation and native inverse is attempted, and combined callback errors reach the owning boundary.

After cancellation, a held button cannot begin another gesture until an observed release and a fresh press. Tracking loss quarantines all pointer buttons until one tracked input sample reports them all up. Reacquisition with a held trigger or a different newly held button cannot activate a surface. Each pointer keeps its own capture and quarantine state. Widget-level exclusive capture is a separate adapter policy; it cannot merge the two hands into one global gesture.

## XR input

lunette uses LÖVR's input verbatim. `lovr.headset` provides poses, buttons, axes, hand tracking, and haptics, covering everything WayVR's custom action sets provide.

Gesture recognition, such as double-tap to show or hide, laser modes, and grab-to-move, is Lua timing logic layered over LÖVR's state. This is also where such tuning is expected to occur.

lunette does not create its own OpenXR action sets. Doing so would require patching LÖVR to expose the `XrInstance` and `XrSession`, and injecting into its once-per-session attach call, for the marginal gain of custom binding names in the runtime's UI. If LÖVR does not provide an input that lunette needs, the preferred fix is to add it to LÖVR.

## Blocking input to the underlying application

With `XR_EXTX_overlay`, controller input reaches the application underneath the overlay as well as the overlay itself. Clicking a panel also triggers actions in the underlying application, such as firing a weapon in a game. OpenXR provides no standard mechanism to prevent this.

WayVR addresses this with libmonado (`inspiration/wayvr/wayvr/src/backend/openxr/blocker.rs`), using `BlockFlags` on Monado API version 1.6 and later, blocking inputs and poses separately, gated by a config switch. lunette takes the same approach.

- `lunette.setGameInputBlocked(inputs, poses)` is the mechanism.
- libmonado is an optional, runtime-detected dependency. On a non-Monado runtime, the call returns `false` and Lua handles the degraded case. lunette does not hard-depend on Monado.
- Blocking policy is decided in Lua. The standard library's default rule matches WayVR's: block while a laser is hovering a panel. Because this is policy, it is implemented in Lua rather than in the native layer.

Haptics use `lovr.headset.vibrate`. No new native API is added for this. In the plugin layer a pointer carries `vibrate`, which the laser supplies for its hand's controller, so a surface a pointer presses can pulse the hand that pressed it; [Keyboard](lua-api.md#keyboard) states it.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

Multi-seat by default, collapsible to one. Faking multi-seat over a single seat is the position WayVR is in; collapsing multi-seat to one seat is a small change.

One current input route coexists with native focus on independent seats. A stack that restored an older route on disposal was rejected because that older target can belong to an ended interaction. Clearing every native seat on a route change was rejected because switching the current input source must not destroy another seat's focus authority. Authority uses stable identifiers because native API reads return fresh Lua wrappers. An omitted seat is normalized through `lunette.defaultSeat`, so native focus and omitted-seat delivery address the same seat.

Pointer cancellation is distinct from release because release can activate a control. Capture remains on the pressed surface while hover changes, so a drag does not transfer to another panel. Tracking reacquisition requires an all-up sample because lost tracking cannot establish which press edges occurred while input was unavailable. The legacy callback fallback remains for external surfaces; the explicit protocol is the source of button identities and cancellation reasons for in-tree controls.

A selected local receiver isolates input even when it declines or fails. Forwarding an unhandled operation to a native sink would type into an application behind a local control. Result kinds distinguish refusal from a reported callback failure without concealing partial native delivery. Inverses retain the original sink and seat because releasing on the new route could leave the old client holding a key or modifier.

Physical committed text is bound to the route before bindings run. LÖVR does not associate each text callback with one preceding key. Suppressing only the next callback was rejected because one consumed key or focus transition can precede several text callbacks. The remaining batch is therefore invalid until the next update. This conservative rule can discard later unrelated text in that batch, but does not send stale text to a replacement target.

Stateless keymap queries serve virtual legends and single-key translation. They do not implement dead-key composition. Physical committed UTF-8 preserves the text LÖVR reports, while Control, Alt, and Logo remain command modifiers and AltGr remains `mod5`. Implicit command or control-character text fallback was rejected because a declined editing command must not insert a control character.

A selection transfer passes the descriptor rather than copying the bytes. lunette never buffers a clipboard's content and never reads or writes a selection pipe. A lunette client pasting supplies a pipe to `wl_data_offer.receive`; smithay hands that descriptor to `SelectionHandler::send_selection`, and it is forwarded unread to `ext_data_control_offer_v1.receive` on the host connection, so the host's own clipboard owner writes into the lunette client's pipe. The host pasting supplies a pipe to lunette's data-control source; the descriptor crosses back to the compositor thread and is handed to `request_data_device_client_selection`, so the lunette client that owns the data writes into the host's pipe. The alternative is what WayVR does (`comp.rs:365-383`): read the bytes, hold them, and spawn a detached thread per request to write them out, with no join, no bound, and no cancellation, so a client requesting the selection in a loop spawns threads without limit. Passing the descriptor removes the whole class of problem rather than bounding it — there is no buffer to size, no worker to schedule, and a client that never reads its pipe stalls only the process that owns the data, exactly as it would with no lunette in the middle. It also removes format negotiation: the MIME list is re-offered exactly as the source advertised it, in both directions, so nothing is substituted and nothing is dropped, and a request for a type the offer does not carry is refused rather than answered with the nearest thing. The cost is that the two ends must both be alive for a transfer to complete, which is already true of any Wayland selection, and that a stale `wl_data_offer` has to be distinguished from a current one: each announcement from the host carries a strictly increasing identifier, and a read quoting a superseded one is refused rather than answered with what the user copied afterwards.

One designated bridge seat for the host clipboard, rather than last writer wins. With one seat per hand, each seat owns a clipboard and a primary selection while the host owns exactly one of each. Letting every seat write the host's clipboard means two hands copying in quick succession race, and which one the host ends up holding depends on the order two commands reach the compositor thread — timing the user cannot see and cannot control, producing a paste of the wrong thing with no way to tell why. Reading is worse: every seat would be offered the same host selection, so the two hands would silently share a clipboard that the rest of the model says is per-seat. One seat is therefore bridged in both directions and the others keep selections that stay inside lunette, which is the arrangement a user can predict — the bridged hand is the one that talks to the desktop. The default is the seat every session starts with, so a configuration that never mentions the clipboard behaves as a single-seat compositor does, and `seat:setClipboardBridge` moves it because which hand is the desktop's is policy. The alternative considered and not taken was merging the two: bridging every seat's clipboard onto the host and reflecting the host's onto all of them. That is last writer wins with extra steps, and it also makes a seat's clipboard change under it because another hand copied.

One layout group per seat, and a configuration naming more than one is refused. Every keymap query in the compositor resolves against layout group zero, and nothing in the API carries a group: `seat:strokeFor` answers with a keycode and modifiers, and `sink:key` takes a keycode. smithay's own keyboard state does track a group and applies layout-switch actions from the keymap, so a seat compiled with `us,de` and `grp:alt_shift_toggle` would have every answer silently drift the moment the user toggled — `sink:typeText('yz')` would emit the keycodes that spell `zy`. The choices were to model the group throughout, threading it through the snapshot, the query signatures, and the typing planner, and to read it back from `KeyboardHandle::with_xkb_state`; or to refuse the configuration. Refusing was taken, because there is no way to *set* the group either, so modelling it would add a parameter nothing could yet control. Lifting it means adding the group to `SeatSnapshot`, to every `Keymap` query, and to `type_text::plan`, plus a way for Lua to read and set it. A configuration wanting a second layout today creates a second seat.

The refusal applies only to a layout a configuration named. A desktop's own default reaches lunette through `XKB_DEFAULT_LAYOUT`, and naming several layouts there is ordinary: NixOS writes the list from `services.xserver.xkb.layout`, and sway and Hyprland export it the same way. Refusing an inherited list would take away the seat of a user who wrote no layout line at all, and a session with no seat has no keyboard, no pointer, and no clipboard. An inherited list is therefore narrowed to its first entry, with the matching variant, and the narrowing is logged with the advice that a second layout wants a second seat. The five `XKB_DEFAULT_*` variables are read by the binary and passed to the compositor as `KeymapDefaults`, rather than left to libxkbcommon to resolve from an empty name. That is what makes the narrowing possible: libxkbcommon offers no way to ask a compiled keymap which RMLVO layout produced it, so a keymap compiled from an empty name cannot be cut down afterwards. It also keeps the compositor crate free of environment reads, so a test states the inherited default rather than depending on the machine it runs on.

The host clipboard's echo is suppressed by ownership, and the suppression is logged. Publishing a selection to the host makes the host announce that selection back on lunette's own data-control device, because a data-control device sees every selection including the ones it set. Re-offering it would replace the lunette client's source with a proxy of itself, so an announcement arriving while lunette owns a live source for that kind is discarded. That rests on the host cancelling a source before announcing the one that replaced it, which is what smithay and wlroots both do and what neither `ext-data-control-v1` nor `zwlr-data-control-v1` states. A host that announced first would have a genuine selection discarded, and lunette's clients would keep pasting the previous one until the next copy — silent, sticky, and indistinguishable from a broken bridge. The alternative considered was a nonce MIME type appended to what lunette publishes, which an echo would carry back and a genuine selection could not. It was not taken because it gives up the property that lunette re-offers a source's own list unchanged, which is the same property that makes the rest of the clipboard path free of substitution. What was taken instead is a warning on every discard, naming the MIME list, so a gate on a real desktop can tell a compositor that announces out of order from a bridge that is broken.

Only a selection lunette owns is ever withdrawn or cleared. `set_selection(null)` is not "stop offering mine" in either data-control protocol: wlroots passes the null straight to `wlr_seat_request_set_selection` and smithay does the same, so it unsets the seat's selection whoever owns it. Sending one while the user's own copy sits on the host clipboard would empty their desktop's clipboard, on an operation both documents describe as safe to call freely. So the bridge records which selections lunette published and withdraws only those, and the compositor clears a seat's selection only when `current_data_device_selection_userdata` reports it as compositor-owned — which is exactly "lunette put this here from the host". A selection a lunette client set is that client's, and moving or removing the bridge is not a reason to destroy it.

## Known gaps

Named, not solved.

Host-to-lunette drag-and-drop. No protocol exists for a drag crossing a compositor boundary. In-compositor drag-and-drop works.

Input blocking is Monado-only. `libmonado`'s `BlockFlags` has no OpenXR-standard equivalent. On other runtimes, clicking a panel also reaches the application underneath.

Multi-seat is less-travelled ground. Toolkit bugs around popup grabs and drag-and-drop ownership are expected.

Virtual activations have no stateful dead-key or compose engine. The local receiver contract accepts committed UTF-8 only; it provides no IME or preedit protocol. Native window routing refuses text the selected keymap cannot represent, and host text retains the native sink's refusal. Neither is an implicit use of the temporary-keymap escape hatch.

Physical keypad routing supports ordinary PC NumLock/Shift behavior from a reliable event snapshot. Arbitrary host keypad remappings and keypad input on backends without a snapshot remain unsupported.

Physical input batches are update-bounded, not a per-key correlation supplied by LÖVR. A route transition, a consumed binding key, or a consumed or failed local key can discard later unrelated text until the next update. XR and host-desktop acceptance of the routing and virtual-keyboard behavior remain unverified.
