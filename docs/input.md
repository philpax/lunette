# Input

## Lua does the raycasting

The chain from controller to application is: XR pose → ray → intersect geometry → surface-local UV → pixel coordinates → client event. We cut it at pixel coordinates.

**Native's primitive is a pixel-space event sink.** Rust knows nothing about 3D.

```lua
local hit = ray:intersectPlane(panel.pose, panel.size)
if hit then
  local x, y = panel:uvToPixels(hit.u, hit.v)
  win.sink:pointer(x, y)
  win.sink:button('left', trigger_pressed)
end
```

Lua already has the poses — it placed the panels — and it has LÖVR's maths, its physics engine, and its shaders. Native doing the intersection would mean Rust knowing about panel geometry, which is precisely the special-casing we're avoiding, and it could only intersect shapes it knows about.

This is what makes the fun things possible. A ball bouncing between windows, where each impact registers as a click, is just a physics callback computing pixel coordinates. So is gaze-driven input, hand tracking, a scripted demo, or a mouse in the desktop simulator — all of them are Lua producing a different pair of numbers.

The standard library ships the boring quad intersection so nobody writes it twice.

Within a surface, **native owns hit-testing** — input regions, subsurfaces, popups. See [Compositor](compositor.md#windows).

## Seats

A `wl_seat` has exactly one pointer and one keyboard. Multiple simultaneous cursors require multiple seats; there's no other mechanism in the protocol.

WayVR sidesteps this with a single seat where "the pointer that was last used to click takes precedence", so pointing your off hand at a window steals hover from your main hand, and two-handed interaction — dragging a slider with one hand while scrolling with the other — isn't expressible.

**Seats are a native primitive Lua creates:**

```lua
local left  = lunette.newSeat('left')
local right = lunette.newSeat('right')
```

Each gets independent pointer position, focus, and keyboard state. The standard library creates one per pointing device by default, and provides a **collapse-to-one-seat mode** for when an application misbehaves. Faking multi-seat on top of one seat is what WayVR is stuck doing; collapsing multi-seat down to one is ten lines of Lua.

Seats are cheap in smithay, which is built for them. The honest cost: popup grabs and drag-and-drop are per-seat, and multi-seat is less-travelled ground in GTK and Qt, so expect occasional toolkit confusion about which seat owns a grab.

The host input domain is always exactly one seat, because your real desktop has one cursor ([Host desktop](host-desktop.md#the-input-domain-leak)).

## Keyboard

Wayland clients want an xkb keymap plus raw keycodes and modifier state; they do their own keysym translation.

**Native provides keycodes plus xkb as data:**

- `sink:key(keycode, pressed)` and explicit modifier state.
- The loaded keymap, exposed for querying: keysym-for-keycode-under-modifiers, the layout list, and reverse `keysym → (keycode, modifiers)` lookup.

That's everything Lua needs to draw a virtual keyboard with correct legends, handle dead keys and AltGr, and implement key repeat — without Rust deciding anything about UI. `xkbcommon` is already a WayVR dependency.

**Key repeat is Lua's job.** It's timing policy, it should feel different per input device, and it's ten lines.

### `sink:typeText(utf8)`

An escape hatch, and explicitly stateful. Typing arbitrary text that the active layout can't express requires generating and uploading a temporary keymap — a known trick, impossible to implement in Lua, and racy with the client's own keymap handling. Documented as: don't interleave it with manual key events.

Needed for clipboard-less paste, voice dictation, and remote control (`lunctl` telling a terminal to run a command).

## XR input

lunette uses **LÖVR's input verbatim**. `lovr.headset` gives poses, buttons, axes, hand tracking, and haptics, and that covers everything WayVR's custom action sets provide.

Gesture recognition — double-tap to show/hide, laser modes, grab-to-move — is Lua timing logic over LÖVR's state, which is where you'd want to tune it anyway.

We don't create our own OpenXR action sets. Doing so would mean patching LÖVR to expose the `XrInstance`/`XrSession` and injecting into its once-per-session attach call, for the marginal gain of custom binding names in the runtime's UI. If LÖVR won't give us an input we need, adding it to LÖVR is the better fix.

## Not shooting people while clicking a menu

With `XR_EXTX_overlay`, your controller input reaches the application underneath **as well as** the overlay. Clicking a panel also fires your gun. OpenXR has no standard way to prevent this.

WayVR's answer is **libmonado** (`inspiration/wayvr/wayvr/src/backend/openxr/blocker.rs`): `BlockFlags` on Monado API ≥ 1.6, blocking inputs and poses separately, gated on a config switch. We take the same approach.

- `lunette.setGameInputBlocked(inputs, poses)` is the mechanism.
- **libmonado is an optional, runtime-detected dependency.** On a non-Monado runtime the call returns `false` and Lua handles the degraded case. We don't hard-depend on Monado.
- **Blocking policy is Lua's.** The standard library's default is WayVR's rule — block while a laser is hovering a panel — but it's a rule, so it lives in Lua.

Haptics come from `lovr.headset.vibrate`. No new API.
