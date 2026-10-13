# Visibility and placement

The keyboard display creates its keyboard lazily. It creates one board when it first needs to show it, then reuses that board. The board is hidden on creation and is offered as a surface only while visible. The display draws the board and its shared titlebar in the `scene` phase at order 1.

A focused local target with `wantsKeyboard = true` requests automatic visibility. When that target stops being the current local target, the display hides the keyboard unless a manual show is active. A manual show survives the end of field editing. A new local target can take focus without repositioning an already visible keyboard.

An explicit hide clears manual and automatic visibility intent. The hide action, titlebar close action, and keyboard's built-in Hide key blur the matching local target only if it still holds focus. They do not blur a newer target. Hiding preserves text-field contents. A later field focus reuses the same board. A board destroyed by owner cleanup clears visibility and notifies listeners with reason `destroy`.

When the display makes the keyboard visible, it places the board in front of the head using the head's horizontal forward direction. It drops the board by `placement.drop` from the head position and tilts it toward the head by `placement.tilt`. A vertical or near-zero horizontal head direction uses forward `-z`. The placement defaults are a distance of 0.55 m, a drop of 0.35 m, and a tilt of pi/6 radians. The display places the board only when it transitions from hidden to visible. It does not follow the head while shown.

The `desktop/keyboard` entry owns the one session keyboard and requires the keyboard, focus, surfaces, UI, and frame providers. A keyboard-display provider outage therefore withdraws display behavior without changing keyboard or focus contract semantics.

## Decisions

The keyboard display observes focus metadata instead of being required by each widget. This avoids a dependency cycle between the keyboard display and local controls.

A single keyboard is shared across local fields. Field changes preserve the current board and its pose. Creating a board per field would duplicate the session keyboard and make field changes reposition it.

Manual visibility is separate from automatic field visibility. A user can keep the keyboard visible after leaving a field. Explicit hide clears both intents and blurs only the target that still holds focus.

The board is placed when it becomes visible and then stays in place. Following the head each frame would move the keyboard while the user works.

## Known gaps

The display does not provide an IME or preedit protocol. Local receivers receive committed text only, as specified in [Input known gaps](../../../../docs/dev/input.md#known-gaps).
