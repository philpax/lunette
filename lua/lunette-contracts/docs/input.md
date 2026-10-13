# Input

Shared guarantees for frame dispatch, focus routing, and pointer interaction are defined here. Contract declarations own service versions and data shapes. Native mechanisms are in [Input](../../../docs/dev/input.md).

## Keyboard routes

The focus service holds one current route: a native sink with an optional seat, or a local Lua receiver. A registered target belongs to its caller's owner. Focusing another target replaces the route; blurring or destroying the current target leaves no route and never restores an older one. Pointer hover is independent. An omitted seat means the default seat, and authority comparisons use stable native identities because each read may return a fresh wrapper.

The Lua route and native seat authority are separate. A native window target takes keyboard focus on its seat before delivering keys. Moving to another seat leaves the earlier seat's native focus in place until its target withdraws it. A later target on the same seat replaces its authority, so destroying an older target cannot clear the newer one. Entering a local route withdraws the previous native window authority. A host sink changes only the Lua route because the host compositor owns keyboard focus.

A source operation selects one target and keeps its identity and route revision through delivery. Re-entrant delivery on one source is refused. If a callback changes the route, the operation stops and never continues on the replacement route. Results distinguish consumed, unhandled, refused, and failed delivery. Unhandled does not forward to another target. Callback failures are reported through `lunette.reportError` and return failed. Delivery is not transactional: native text may deliver a prefix before a later character is refused.

Every native key press records its release and modifier clear on the original sink and seat before changing them. Reset, route loss, and source disposal run those inverses against the original target, never the current route; releasing through a new route could leave the old client holding a key. A refused or raising inverse blocks later delivery from that source. A local receiver remains isolated when it declines or fails, so declining input cannot fall through to an application behind a local control.

### Virtual activations and committed text

A virtual source sends evdev activations with explicit modifiers, not a held-key stream. A local receiver gets the key first. If it declines and the route is unchanged, the source may translate the activation into one printable character for that same receiver. Control, Alt, and Logo chords and C0/C1 control characters never produce fallback text. Right Alt remains distinct from Alt and represents AltGr through `mod5`. Committed UTF-8 text is a separate source operation.

Virtual translation and legends use one keymap seat: the local target's live `keymapSeat`, then the most recently focused live native seat, then the first live seat. With no live seat, a virtual activation produces no translated text. The native keymap query has no dead-key or compose state.

A physical source keeps key events and committed text separate. A local receiver gets physical keys without text fallback and receives committed UTF-8 through its text callback. Native physical keys defer printable characters to committed text unless they form a command chord, preventing one keystroke from producing two characters. Native window text resolves each character through the seat keymap and refuses an unrepresentable character rather than using arbitrary native text entry.

### Physical input batches

The frame service opens a batch before each update's handlers, or when the first key or text callback arrives if no batch is open. Key and text callbacks until the next update share the batch. Owner-scoped batch observers run before update, binding, and delivery handlers. A physical source records its route revision at this boundary, before a binding can change focus.

The frame provider translates each host key event once, so every handler sees the same evdev code and modifier state. A missing evdev name gives no code. Modifier names come from the host snapshot when available, otherwise from keys held at the callback. The separate physical modifier snapshot is optional when the backend cannot report it at the host-event boundary. Text events carry the modifiers held at their callback. The focus provider's keypad policy uses the optional snapshot ([Routing and delivery](../../lunette-plugins/focus/docs/routing.md)).

Committed text is eligible only while the route still has the revision recorded at batch start. Any route transition invalidates the batch's remaining text, even if focus returns to the same target. A binding that consumes a key blocks text for the rest of that batch. A delivery consumer also blocks the remainder after a command chord, a consumed, failed, or refused key, failed or refused text, or source release. This prevents a replacement source from receiving stale text after the original source ends. The block lasts until the next update; it does not suppress later key activations. The whole batch is blocked because LÖVR does not associate text callbacks with the preceding key, and one key or route transition may precede several text callbacks. This can discard unrelated later text, but does not deliver stale text to a new route.

## Surface pointer delivery

The interaction service separates hover from a captured gesture. Lua pointer input is delivered to surfaces without native sinks; a surface with a native sink receives native motion, buttons, and scroll instead. Captures belong to one pointer and button. Captured movement and release continue to the pressed surface while another surface is hovered, and hover leave does not end capture. Picking uses bounded coordinates; a surface may project unbounded coordinates for a captured drag outside its bounds.

The interaction contract declares every pointer-event property read-only, so each event is a read-only snapshot. It reports surface-local coordinates when available, whether the pointer is inside, and whether the gesture is captured. A captured move carries its button. Scroll values are emitted after the pointer's dead zone, scale, and inversion.

Tracking loss, pointer destruction, a dead or withdrawn surface, provider replacement, a hidden panel, a removed or disabled control, and a grab cancel affected gestures with a reason. Cancellation never activates a control. A pointer can cancel its gestures on one surface. Starting a grab cancels Lua captures before the surface moves; native pressed sinks still receive their releases.

Cancellation is distinct from release because release can activate a control. Capture keeps movement on the pressed surface so a drag cannot migrate to a newly hovered surface. After cancellation, a held button cannot begin a new gesture until released and pressed again. After tracking loss, all buttons remain blocked until one tracked sample reports them all up, because tracking loss can hide press and release edges. Capture and recovery state are private to each pointer; consumers use pointer events and cancellation rather than manipulating provider state. The input sample's button map makes each held pointer button explicit, so a right click or remapped trigger does not require a new provider API. A replacement interaction provider preserves these rules. A pointer's optional vibration callback is supplied by its creator, so a surface can pulse the associated device without the interaction service inferring controller ownership; calling it without a callback returns false.

## Frame dispatch

The frame service updates handlers in `input`, `scene`, `pointing`, and `overlay` phases, then draws in those phases followed by `feedback`. Input reads devices before the scene moves; pointing resolves against this frame's surface poses; feedback draws pointer beams after overlay UI. Handlers within a phase run by ascending order and then registration order. Key and text handlers run in `binding` before `delivery`. Returning true consumes a key or text event. Quit handlers cannot veto quit.

Each handler and each surface offer's `list` callback has its own protected call. A key or text handler that raises consumes nothing. An offer that raises or returns a non-table contributes no surfaces. Callback installation and start/stop wiring belong to the [frame provider](../../lunette-plugins/frame/README.md).

## Drops

A drop notification reports the surface and pointer when a grab ends. Desktop pose memory and arrangement save listen through the drops service rather than interaction internals. Any replacement provider that carries surfaces and supports grabs emits the drop before clearing the pointer's carried surface, so listeners can inspect the ending surface. A surface moved on behalf of a panel carries the panel's kind and source so listeners can resolve it through the panels service.

## Decisions

A route stack that restored an older target on disposal was rejected because that target may belong to an interaction that has ended. Clearing every native seat on a route change was rejected because switching input sources must not destroy another seat's focus. Focus remains a separate contract so keyboards and local receivers do not require a pointer provider.

## Known gaps

Virtual input has no dead-key or compose engine. Local receivers have no IME or preedit protocol. Physical batches are bounded by updates rather than correlated per key, so invalidating a batch can discard unrelated later text.
