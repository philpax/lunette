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

Each seat has independent pointer position, focus, and keyboard state. The standard library creates one seat per pointing device by default, and provides a collapse-to-one-seat mode for applications that misbehave with multiple seats. WayVR is limited to faking multi-seat behaviour on top of one seat; collapsing multi-seat down to one seat requires a small amount of Lua code.

Seats are inexpensive in smithay, which is designed to support them. The cost is that popup grabs and drag-and-drop are per-seat, and multi-seat operation is less exercised in GTK and Qt, so toolkit confusion about which seat owns a grab can occur.

The host input domain is always exactly one seat, because the host desktop has one cursor. See [Host desktop](host-desktop.md#the-input-domain-leak).

## Keyboard

Wayland clients want an xkb keymap plus raw keycodes and modifier state; they do their own keysym translation.

The native layer provides keycodes plus xkb data:

- `sink:key(keycode, pressed)` and explicit modifier state.
- The loaded keymap, exposed for querying: keysym-for-keycode-under-modifiers, the layout list, and reverse `keysym → (keycode, modifiers)` lookup.

This is sufficient for Lua to draw a virtual keyboard with correct legends, handle dead keys and AltGr, and implement key repeat, without the native layer deciding anything about UI. `xkbcommon` is already a WayVR dependency.

Key repeat is implemented in Lua. It is timing policy, it should differ per input device, and it requires a small amount of code.

### `sink:typeText(utf8)`

This is an escape hatch and is explicitly stateful. Typing arbitrary text that the active layout cannot express requires generating and uploading a temporary keymap. This technique cannot be implemented in Lua, and is subject to a race with the client's own keymap handling. Documentation states that it must not be interleaved with manual key events.

It is needed for clipboard-less paste, voice dictation, and remote control, for example `lunctl` instructing a terminal to run a command.

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

Haptics use `lovr.headset.vibrate`. No new API is added for this.
