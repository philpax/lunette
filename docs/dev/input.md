# Input

## Lua does the raycasting

The chain from controller to application runs from XR pose, to ray, to intersected geometry, to pixel coordinates, to a client event. The native layer and Lua meet at pixel coordinates. The native primitive is a pixel-space event sink, and Rust has no knowledge of the 3D scene.

```lua
local quad = require '@lunette-contracts/quad'

local x, y = quad.hit({
  pose = pose, width = width, height = height,
  pixelWidth = win.width, pixelHeight = win.height,
}, origin, direction)
if x and win.sink then
  win.sink:pointer(x, y)
  win.sink:button('left', pressed)
end
```

Lua placed the panels, so it has their poses, and it has LÖVR's maths, physics, and shaders. Intersection in Rust would require Rust to know panel geometry and would limit input to shapes Rust knows. With intersection in Lua, a gaze ray, a hand-tracking pinch, a scripted demo, or a physics impact each reach a window as a different pair of numbers, without native changes. `@lunette-contracts/quad` supplies the flat-quad intersection.

Within a surface, the native layer hit-tests input regions, subsurfaces, and popups. See [Compositor](compositor.md#windows).

## Seats

A `wl_seat` has one pointer and one keyboard, so simultaneous cursors require multiple seats. WayVR uses one seat, where the pointer that clicked last takes precedence, so pointing the off hand at a window steals hover from the main hand.

Seats are a native primitive that Lua creates:

```lua
local left = lunette.newSeat { name = 'left' }
local right = lunette.newSeat { name = 'right' }
```

Each seat has its own pointer position, focus, and keyboard state. Hover and focus are separate requests: `sink:pointer` and `sink:leave` move the pointer, and `seat:setFocus` gives the keyboard. A hand pointing at a panel therefore does not take the keyboard from the other hand. Each laser creates its own seat unless its attachment names one, so a configuration that wants one seat passes the same seat to both lasers.

smithay supports seats directly. Popup grabs and drag-and-drop are per seat, and GTK and Qt exercise multi-seat less, so toolkit confusion over which seat owns a grab can occur.

The host input domain is always one seat, because the host desktop has one cursor. See [Host desktop](host-desktop.md#the-input-domain-leak).

## Clipboard

Each seat owns a clipboard and a primary selection, because smithay stores both against the seat. The host desktop owns one of each. One designated bridge seat connects the two: its selections are the host's in both directions, and every other seat's selections stay inside lunette.

```lua
lunette.seats()[1].clipboardBridge   -- Whether this seat's selections are the host's.
seat:setClipboardBridge(true)        -- Moves the bridge to this seat.
seat:setClipboardBridge(false)       -- Leaves no seat bridged, if this one held it.
```

A selection the host sets is offered to the bridge seat. A selection set on the bridge seat is pushed to the host. A selection set on another seat is offered only to clients focused on that seat. The session's first seat starts as the bridge. A change takes effect at the next frame boundary. A selection the newly bridged seat already held is not pushed retroactively; the next copy crosses.

MIME types are re-offered exactly as the source advertised them, and a request for a type the offer does not carry is refused. A transfer passes a file descriptor between the two processes that own the data, so lunette buffers nothing.

## Keyboard

Wayland clients take an xkb keymap, raw keycodes, and modifier state, and translate keysyms themselves. The native layer provides:

- `sink:key(keycode, pressed)` and explicit modifier state through `sink:setModifiers`. The state is set directly, without synthesising presses of a representative key. Modifier names are the closed set `lunette.ModifierName`, which `lunette.modifierNames()` lists.
- Keymap queries: `seat:symbolFor` and `seat:characterFor` give the keysym and text for a keycode under modifiers, and `seat:strokeFor` is the reverse lookup from keysym or character to keycode and modifiers.
- `sink:scroll` for a continuous distance in surface pixels. A host sink converts the distance to wheel detents.

On a host sink, a key or modifier change is read under the seat's layout, which is uploaded to the host's input provider first; a seat absent from the frame's snapshot, or whose layout cannot be uploaded, has its key refused. [Host desktop](host-desktop.md#input-injection) describes the providers.

A seat carries one layout group. A configuration that names several layouts for one seat is refused, and a second layout requires a second seat. `lua/lunette/init.luau` declares each call.

The keymap queries are stateless. They serve virtual-keyboard legends and single-key translation under explicit modifiers, including AltGr, and keep no dead-key or compose state. Physical text uses LÖVR's committed UTF-8.

A seat tells its clients to repeat a held key after 500 ms at 50 repeats per second, WayVR's values, unless `lunette.newSeat` sets `repeatDelay` or `repeatRate`. Clients repeat keys themselves; whether a key is held is Lua policy, and the virtual keyboard sends single activations.

### `sink:typeText(utf8)`

`sink:typeText` enters arbitrary text. The compositor resolves each run through the seat's layout and, for a run the layout cannot express, uploads a temporary keymap and restores the original afterwards. The temporary keymap races with the client's own keymap handling, so `typeText` must not be interleaved with manual key events. It serves clipboard-less paste, dictation, and remote control such as `lunctl` typing a command into a terminal.

## Keyboard routing

The `lunette/focus` schema 2 contract holds one current keyboard route. A route is a native sink with an optional seat, or a local Lua receiver with key and text callbacks. A registered target belongs to its caller's owner, and its handle focuses, blurs, or destroys it. Blurring or destroying the current target leaves no route and never restores an older one. Pointer hover is independent of the route.

Native seat authority is separate from the route. A native window target takes its seat's keyboard with `seat:setFocus(sink)` before delivering keys. Moving the route to a target on another seat leaves the earlier seat's focus in place until its target withdraws it. A later target on the same seat replaces the authority, so destroying the older target cannot clear the newer focus. Entering a local route withdraws the previous native window authority. A host sink target changes only the Lua route, because the host compositor owns its keyboard focus.

An omitted seat means `lunette.defaultSeat()`. Authority comparisons use stable seat, window, and monitor identifiers, because native reads return fresh Lua wrappers.

An owner creates an input source with `focus:newSource`. Each operation selects one target and keeps its identity and route revision until delivery ends. Re-entrant delivery on one source is refused. A route change during a callback stops the rest of the operation; input never continues on the new route.

A delivery answers `consumed`, `unhandled`, `refused` with a message, or `failed` with a message. `unhandled` never forwards to another target, so a local receiver that declines a key does not send it to a native client. A callback error is reported through `lunette.reportError` and answers `failed`. A result is not a transaction: multi-character native text can deliver a prefix before a later character is refused.

Every native stroke records its key release and modifier clear on the original sink and seat before it mutates them. Reset, route loss, and source disposal run those inverses on the original target, never on the current one. A refused or raising inverse blocks later delivery from that source.

### Virtual activations and committed text

A virtual source delivers evdev activations with explicit modifiers, not a held-key stream. A local receiver gets the key first. If it declines and the route is unchanged, the source may translate the activation into one printable character for the same receiver. Control, Alt, and Logo chords never produce this fallback text, and neither do C0 or C1 control characters. Right Alt is AltGr, represented by `mod5`, and stays distinct from Alt. `source:text` delivers committed UTF-8 as a separate operation.

Virtual translation and legends use one keymap seat: the local target's live `keymapSeat`, then the most recently focused live native seat, then the first live seat. Without one, a virtual key produces no text. The keyboard clears latched and locked modifiers when the route changes, when it hides, and when it is destroyed, and a non-modifier activation consumes the latches before receiver code runs.

A physical source keeps keys and text apart. A local receiver gets physical keys without text fallback and receives committed UTF-8 through its text callback. For native delivery, printable physical keys wait for committed text unless they form a command chord, so one keystroke does not produce two characters. Native window text resolves each character through the seat's `strokeFor`, and a character the keymap cannot represent is refused rather than typed through `sink:typeText`.

### Physical input batches

The `lunette/frame` schema 2 contract opens an input batch before each update's handlers, or at the first key or text callback when no batch is open. Callbacks until the next update share its identifier. Owner-scoped `onBatch` observers run before update, binding, and delivery handlers, and a physical source records the route revision there, before a binding can change the route.

The frame provider translates each host key event once, so every key handler sees the same press. The event carries the evdev `code` of LÖVR's key name, or none for a key with no evdev name, and `modifiers`, the held modifier names. With a host snapshot the names come from it; without one they come from the keys held at the callback. Text events carry the modifiers held at the callback. `lua/lunette-plugins/frame/translation.luau` holds the key map and the translation. The bindings provider matches chords against these modifiers and `desktop/input` delivers them, so a binding and a focus route never disagree about one press.

Committed text is eligible only while the route keeps the revision recorded at the batch start. Any route transition, including one that returns to the same target, invalidates the rest of the batch's text. So does a binding key handler that consumes a key, and the frame provider then republishes the batch with `textBlocked=true`. `desktop/input` blocks the batch through `frame:blockText` after a command chord or a consumed, failed, or refused key, after failed or refused text, and when its source is released, so a replacement source cannot deliver the rest of that batch's text. Eligibility returns at the next update. Invalidating text does not suppress later key activations.

### Physical keypad modes

LÖVR's key callback supplies a snapshot of held Shift, Control, Alt, and Super and enabled Caps Lock and Num Lock, taken at the event. The frame provider carries it on the key event as `physicalModifiers`, with Super named `logo` as the seat names it. `lovr.system.isKeyDown('numlock')` observes only a held key, not the lock state. The snapshot combines left and right Alt, so the frame provider reads the sided keys to tell Alt from AltGr. A physical source takes the snapshot with the activation and uses it only for the keypad rule below; `lua/lunette-plugins/focus/physical.luau` holds that rule and the printable set.

Native keypad routing follows ordinary PC behaviour from the snapshot. Num Lock on without Shift is numeric input, delivered as committed text. Num Lock off, or Shift with Num Lock, is navigation, delivered as mapped keycodes. A keypad digit or decimal key without a snapshot is refused rather than guessed. Local receivers receive the mapped activation and the committed text separately.

## Surface pointer input

The `lunette/interaction` schema 2 contract separates hover from a captured gesture. A surface receives Lua pointer input through `onPointer(event)` and can supply `project(origin, direction)` for unbounded coordinates. Events are `enter`, `move`, `leave`, `press`, `release`, `scroll`, and `cancel`. A surface with a native sink receives native motion, buttons, and scroll instead.

An event is a read-only snapshot carrying the pointer, surface-local `x` and `y` when available, and `captured` and `inside` flags. Press and release name a button, and so does a captured move. Scroll carries `dx` and `dy` after the pointer's dead zone, scale, and inversion. Cancellation carries its button and a reason.

Capture belongs to one pointer and button. Captured movement and release reach the pressed surface while another surface is hovered, and a hover leave does not end capture. `raycast` gives bounded coordinates for picking, and `project` gives unbounded coordinates for a captured drag outside the bounds. `quad.project` intersects a flat plane without clipping, and `quad.hit` applies the quad's bounds; both reject non-finite input, a parallel or behind-origin ray, a back face unless `backFace` is set, and a pose that does not invert.

Tracking loss, pointer destruction, a dead or withdrawn surface, provider replacement, a hidden panel, a removed or disabled control, and a grab each cancel a gesture with the matching reason. Cancellation never activates. `pointer:cancel(surface, reason)` ends a pointer's gestures on one surface. A grip that begins a grab cancels Lua captures before the surface moves, and native pressed sinks still receive their button releases.

After cancellation, a held button cannot start a gesture until it is released and pressed again. After tracking loss, every button of that pointer stays blocked until one tracked sample reports them all up. Each pointer keeps its own capture state.

## Drag and drop

A native window starts a drag from a press, and the seat's pointer carries it wherever Lua moves the pointer next. The drag needs nothing beyond the ordinary routing: hovering a panel moves the seat's pointer onto that panel's sink, leaving a panel withdraws it, and the release goes to the sink the button was pressed on. The native layer accepts that release wherever the pointer is, and the drag drops on the window under the pointer at that moment, or on nothing. The laser draws the drag's icon where its beam ends ([Lasers](lua-api.md#lasers)). [Compositor](compositor.md#drag-and-drop) describes the drag itself.

## XR input

lunette uses LÖVR's input API. `lovr.headset` provides poses, buttons, axes, and haptics. Gesture recognition, laser modes, and grab-to-move are Lua timing logic over that state.

lunette creates no action sets outside LÖVR. For OpenXR, doing so would require patching LÖVR to expose the `XrInstance` and `XrSession` and joining its once-per-session attach call, for the gain of custom binding names. An input lunette needs and LÖVR lacks is added to LÖVR.

The OpenVR backend initialises its action manifest before polling events or updating actions, and samples head and hand actions once per accepted frame. An open SteamVR dashboard clears buttons, touches, axes, and scheduled haptics and keeps valid poses; input resumes with the next sample after the dashboard closes. Failed samples and recentring invalidate tracking. Grip and aim stay distinct, and aim is never substituted for grip. Touch grip poses, hand tracking, skeletons, and controller models are unavailable in this backend. [LÖVR integration](lovr-integration.md#backend-selection) states backend selection.

Haptics use `lovr.headset.vibrate`. A pointer carries `vibrate`, which the laser supplies for its hand's controller, so a surface can pulse the hand that pressed it. The OpenVR backend schedules pulses of at most 20 ms, and a frequency of zero selects 120 Hz.

## Blocking input to the underlying application

With `XR_EXTX_overlay`, controller input reaches both the overlay and the application underneath, so clicking a panel can also fire a weapon in a game. OpenXR has no standard way to prevent this. WayVR blocks inputs and poses through libmonado's `BlockFlags` on Monado API 1.6 and later. lunette specifies the same mechanism as `lunette.setGameInputBlocked(inputs, poses)`, with libmonado detected at runtime and the call answering `false` on other runtimes, and blocking policy in Lua: by default, block while a laser hovers a panel. It is not implemented.

## Decisions

Seats are multiple by default. Collapsing multiple seats to one is a small change in Lua; faking multiple seats over one, which WayVR does, is not possible to do well.

One current route coexists with independent native seat focus. A stack that restores an older route on disposal was rejected, because the older target can belong to an ended interaction. Clearing every seat on a route change was rejected, because switching the input source must not destroy another seat's focus.

A release is accepted on the sink its button was pressed on, wherever the seat's pointer is, and a press only on the sink the pointer is over. The pressed client holds smithay's implicit grab until the release, and a drag drops on it. Lua releases on the sink it pressed after its hover has moved to another panel or to nothing, so refusing that release, as other input to a sink the pointer is not over is refused, left the button held and a drag that never ended.

Pointer cancellation is distinct from release, because a release can activate a control. Capture stays on the pressed surface so a drag does not move to another panel. Reacquired tracking requires an all-up sample, because lost tracking cannot tell which press edges happened meanwhile.

A selected local receiver isolates input even when it declines or fails. Forwarding to a native sink would type into an application behind a local control. Inverses stay on the original sink and seat, because releasing on the new route could leave the old client holding a key.

Physical text is bound to the route recorded before bindings run. LÖVR does not associate a text callback with the key that preceded it, and one consumed key or route change can precede several text callbacks, so suppressing only the next callback was rejected. The rest of the batch is invalid instead. This can discard unrelated later text in the batch but never sends stale text to a new target.

Implicit text fallback is never produced for command chords or control characters, because a declined editing command must not insert a control character.

A key event is translated once, in the frame provider that owns `lovr.keypressed`. Translating in each consumer was rejected because a consumer that polls held keys and one that reads the host snapshot see one press with two modifier sets, so a chord could match a binding that the window then receives differently. The key map and modifier translation are LÖVR-specific, so they live with the frame provider rather than in `@lunette-contracts/keys`, which keeps only the shared vocabulary: the runtime's codes, the modifier each modifier key holds, the host snapshot type, and which modifiers make a command chord.

A selection transfer passes the descriptor. A lunette client's paste pipe is forwarded unread to the host's data-control offer, and the host's paste pipe is handed to the owning lunette client. WayVR reads the bytes and spawns an unbounded, unjoined thread per request to write them out. Passing the descriptor removes buffering, scheduling, and format negotiation: a client that never reads its pipe stalls only the data's owner. Each host announcement carries an increasing identifier, and a read that quotes a superseded one is refused.

One bridge seat carries the host clipboard. With every seat writing the host's clipboard, two hands copying in quick succession race on command order the user cannot see, and every seat would read the same host selection, which contradicts per-seat clipboards. Which hand is the desktop's is policy, so Lua moves the bridge.

A seat carries one layout group. smithay tracks a group and applies layout-switch actions, but nothing in the API carries a group: `strokeFor` answers a keycode and modifiers, and `sink:key` takes a keycode. A seat compiled with `us,de` and a toggle option would drift after a toggle, so `typeText('yz')` would type `zy`. Modelling the group was rejected because nothing could set it. The refusal applies only to a layout a configuration names. The binary reads the `XKB_DEFAULT_*` variables and passes them to the compositor as `KeymapDefaults`; an inherited list of several layouts is narrowed to its first entry and the narrowing is logged, because refusing it would leave a user who wrote no layout without a seat. Reading the variables in the binary keeps the compositor free of environment reads.

The host clipboard's echo is suppressed by ownership. A data-control device sees selections it set itself, so an announcement that arrives while lunette owns a live source of that kind is discarded and logged. This relies on the host cancelling a source before announcing its replacement, which smithay and wlroots do and neither protocol states. A nonce MIME type marking lunette's own offers was rejected, because it would change the MIME list lunette re-offers.

lunette withdraws or clears only selections it owns. `set_selection(null)` unsets the seat's selection whoever owns it in both data-control protocols, so withdrawing freely would empty the user's own clipboard. The bridge withdraws only what it published, and the compositor clears a seat's selection only when it is compositor-owned.

## Known gaps

The OpenVR controller bindings and haptic frequency mapping need SteamVR hardware validation. Steam Frame controller poses and buttons are bound, and panel interaction has been observed with both controllers. HMD activity is inferred from use, not from wear detection.

Drag-and-drop from the host into lunette has no protocol. Drag-and-drop inside lunette works.

Input blocking is not implemented, and the specified mechanism is Monado-only. On every runtime, clicking a panel also reaches the application underneath.

Multi-seat is less exercised in toolkits. Bugs around popup grabs and drag-and-drop ownership are expected.

Virtual activations have no dead-key or compose engine, and local receivers have no IME or preedit protocol. Native window routing refuses text the keymap cannot represent.

Keypad routing supports ordinary PC Num Lock and Shift behaviour. Host keypad remappings and backends without a modifier snapshot are unsupported.

Physical batches are bounded by updates, not correlated per key, so a route change, consumed binding key, or consumed or failed local key can discard unrelated text until the next update.
