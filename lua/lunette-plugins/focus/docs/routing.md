# Routing and delivery

The focus provider keeps one current route for keyboard input. A target is either a native sink with an optional seat or a local receiver with key and text callbacks. Target registrations belong to their caller's owner. Focusing a target replaces the current route. Blurring or destroying it leaves no route and does not restore an older target.

Native seat keyboard authority is separate from the current Lua route. Before delivering to a native window target, the provider sets that sink as the seat's focus. Changing the Lua route to a target on a different seat leaves the previous seat's native focus in place. A newer target on the same seat replaces its authority. Destroying an older target therefore cannot clear the newer focus. Entering a local route withdraws the previous native window authority. A host sink changes only the Lua route because the host compositor owns keyboard focus. An omitted seat uses `lunette.defaultSeat()`.

The provider compares native authority by stable seat, window, and monitor identifiers because native reads return fresh Lua wrappers. Native target liveness is checked on frame updates and before input batches. If the current native sink or its explicit seat dies, the provider withdraws the route.

Each input source snapshots one target identity and route revision at the start of each operation. Re-entrant delivery on one source is refused. A route change during a callback or between characters stops the operation. Delivery never continues on a newly focused route. Results are `consumed`, `unhandled`, `refused` with a message, or `failed` with a message. `unhandled` does not forward to another target. Callback errors are reported through `lunette.reportError` and produce `failed` results. A multi-character native text operation is not transactional: a prefix can reach the target before a later character is refused.

Each native stroke records the key release and modifier clear against the original sink and seat before mutating either. Reset, route loss, and source disposal run those inverses against the original target, not the current route. A refused or raising inverse blocks further delivery from that source.

A virtual source sends evdev activations with explicit modifiers, not a held-key stream. A local receiver gets the key first. If it declines the key and the route remains unchanged, the source can translate that activation into one printable character for the same receiver. Control, Alt, and Logo chords do not use this fallback. C0 and C1 control characters do not use it either. Right Alt is `mod5`, not Alt. `source:text` delivers committed UTF-8 as a separate operation.

Virtual translation and keyboard legends use one keymap seat in this order: the local target's live `keymapSeat`, the most recently focused live native seat, then the first live seat. A virtual key produces no fallback text without a live seat.

A physical source never converts a key activation into fallback text. A local receiver gets physical keys and committed UTF-8 through separate callbacks. For native delivery, printable keys wait for committed text unless the key forms a command chord. Native window text resolves each character through the seat's `strokeFor`; the provider refuses a character the keymap cannot represent rather than sending it through `sink:typeText`.

## Physical keypad policy

LÖVR's key callback supplies a snapshot of Shift, Control, Alt, and Super, plus enabled Caps Lock and Num Lock, taken at the event. `frame` carries it as `physicalModifiers`. `lovr.system.isKeyDown('numlock')` reports only whether the key is held, not the lock state. The snapshot combines left and right Alt; the frame provider reads the sided keys to distinguish Alt from AltGr. The physical source takes the snapshot with the activation and uses it only for the keypad rule.

Native keypad routing follows ordinary PC behavior. Num Lock on without Shift is numeric input delivered as committed text. Num Lock off, or Shift with Num Lock on, is navigation delivered as mapped keycodes. A keypad digit or decimal key without a snapshot is refused rather than guessed. Local receivers receive the mapped activation and committed text separately.

## Decisions

The current keyboard route coexists with independent native seat focus. A stack that restores an older route on disposal was rejected because that target can belong to an ended interaction. Clearing every seat on a route change was rejected because switching the input source must not destroy another seat's focus.

A selected local receiver isolates input even when it declines or fails. Forwarding to a native sink would type into an application behind a local control. Inverses stay on the original sink and seat because releasing on the new route could leave the old client holding a key.

Physical text is bound to the route recorded before bindings run. LÖVR does not associate a text callback with the key that preceded it, and one consumed key or route change can precede several text callbacks. Suppressing only the next callback was rejected. The rest of the batch is invalid instead. This can discard unrelated later text in the batch but never sends stale text to a new target.

Implicit text fallback is never produced for command chords or control characters because a declined editing command must not insert a control character.

## Known gaps

Virtual activations have no dead-key or compose engine, and local receivers have no IME or preedit protocol. Native window routing refuses text the keymap cannot represent.

Keypad routing supports ordinary PC Num Lock and Shift behavior. Host keypad remappings and backends without a modifier snapshot are unsupported.

Physical batches are bounded by updates, not correlated per key. A route change, consumed binding key, or consumed or failed local key can discard unrelated text until the next update. The frame provider records its batch and text-blocking behavior in [Input batches](../../frame/docs/input-batches.md).

Shared native seat lifecycle, multi-seat toolkit behavior, and related runtime limitations remain in [Input](../../../../docs/dev/input.md#known-gaps).
