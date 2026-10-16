# Input

Consumers and replacement providers preserve these frame, focus, and pointer guarantees. [Contract declarations](..) own service versions and shapes; [native input](../../../docs/development/native/input.md) owns seats and sinks.

## Keyboard routes

Focus holds one route to a native sink and optional seat, or a local receiver. Targets belong to their caller's owner. Replacing focus changes the route; blur or disposal clears it without restoring an older route. Hover is independent. Omitted seats use the default, and authority comparisons use stable native identities.

Lua routing and native seat focus are separate. A window target takes its seat's authority; switching seats leaves earlier native focus until its target withdraws it. Disposing an old target cannot clear a later target's authority. A local route withdraws the preceding window authority; host sinks cannot change host-compositor focus.

Delivery selects one target and route revision. Route changes stop the operation without forwarding to the replacement. Re-entrant delivery is refused, and unhandled input never falls through to another target. Callback failures report an error. Delivery is not transactional; native text may deliver a prefix before refusal.

Key releases and modifier clearing go to the original sink and seat on reset, route loss, or source disposal. A refused or raising inverse blocks later delivery from that source, preventing stuck keys from being transferred to a new route.

### Virtual activations and committed text

Virtual sources send evdev activations with explicit modifiers. A local receiver gets the key first, then printable fallback text only if it declines and the route is unchanged. Command chords and control characters have no fallback; Right Alt remains distinct as AltGr. Translation uses the target's live keymap seat, the most recently focused live native seat, or the first live seat. Without one, there is no translated text.

Physical keys and committed text stay separate. Local receivers get no physical-key text fallback. Native printable keys defer to committed text unless they form a command chord. Native window text refuses characters its seat keymap cannot represent.

### Physical input batches

Keys and text until the next update share a batch. Batch observers run before update, binding, and delivery handlers, so physical sources record the route revision before bindings can change focus. The frame provider translates each key once. Physical modifier snapshots are optional when the backend cannot report them; text uses modifiers held at its callback.

A route transition invalidates remaining committed text even if focus returns to the same target. A consumed binding, command chord, consumed or failed or refused key, failed or refused text, or source release blocks the batch's remaining text. The block ends at the next update and does not block later keys. LÖVR does not correlate text with a preceding key, so a whole batch is suppressed to avoid stale text reaching a replacement route or source; unrelated later text can be discarded.

## Surface pointer delivery

Hover and capture are separate. Native sinks receive native input; sinkless surfaces receive Lua events. A pointer and button capture the pressed surface through movement and release, even when another surface is hovered. Picking uses bounded coordinates; captured drag projection may be unbounded. Events are read-only snapshots, and scroll already includes pointer scaling and inversion.

Tracking loss, pointer or surface withdrawal, provider replacement, hidden panels, disabled or removed controls, and grabs cancel affected gestures. Cancellation never activates a control. Grabs cancel Lua captures before movement and release native pressed sinks. A held button cannot start another gesture until released; after tracking loss, all buttons stay blocked until a tracked sample reports all up. Recovery is private to each pointer.

Vibration uses the callback supplied by the pointer's creator and returns false when none exists. Providers must not infer controller ownership.

A pointer's captures move to another surface only through `transfer`, which delivers no release or cancel; the receiving surface sees the press's later motion and its release. Press observers run when any button goes down, before the pressed surface receives the press, with the pressed surface or nil for a press on nothing or on a native sink. A hand reported near stands its idle ray down: the ray delivers no hover and draws nothing until no owner reports the hand, and a ray that holds a button or a grab keeps working until it is idle for a frame. Near reports and press observers end with their owners.

## Frame dispatch

Update phases run `input`, `scene`, `pointing`, and `overlay`; drawing adds `feedback` last. Pointing therefore uses current scene poses, and feedback draws after UI. Within a phase, ascending order precedes registration order. Key and text dispatch runs `binding` before `delivery`; true consumes the event. Quit handlers cannot veto quit.

Each handler and surface offer has a protected call. Raising key or text handlers consume nothing; invalid or raising offers contribute no surfaces. The [frame provider](../../lunette-plugins/session/frame/README.md) owns callback installation.

## Drops

A provider that carries surfaces emits a drop before clearing the carried surface, so listeners can inspect it. A panel-backed surface includes its panel kind and source for resolution. Desktop placement memory listens to drops rather than interaction internals.

## Known gaps

Virtual translation has no dead-key or compose state. Local receivers have no IME or preedit protocol. Update-bounded physical batches can discard unrelated text after invalidation.
