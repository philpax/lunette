# lunette v1 Implementation Plan — Phase 5: Keyboard, seats, and clipboard

**Goal:** Text entry and copy-paste across the boundary, with two hands usable independently.

**Architecture:** One `wl_seat` per hand, each with independent pointer position, focus, keyboard state, and selection. `hit_test.rs` ports across stripped of its GPU and XR couplings, leaving a pure geometry function over pixel coordinates. Keymaps are uploaded to smithay as strings because libxkbcommon is not thread-safe. Clipboard bridges both directions for both the regular selection and the primary selection, through one designated seat.

**Tech Stack:** smithay 0.7 `SeatState`/`Seat`, xkbcommon 0.8.0, `wl_data_device`, `zwp_primary_selection_v1`, `zwlr_data_control_v1`, `ext_data_control_v1`.

**Scope:** Phase 5 of 8. Specified at intent level in the design; task detail derives from investigation.

**Codebase verified:** 2026-08-06.

---

## Acceptance criteria coverage

### lunette-v1.AC4: Text and clipboard work, with two hands
- **lunette-v1.AC4.1 Success:** Two seats hover two different windows simultaneously, each with its own pointer position and focus.
- **lunette-v1.AC4.2 Success:** Keycodes with modifier state produce the characters the active xkb layout defines.
- **lunette-v1.AC4.3 Success:** `Sink:typeText` enters text the active layout cannot express, and the client's own keymap handling is restored afterwards.
- **lunette-v1.AC4.4 Success:** A click at a pixel covered by a popup is delivered to the popup's surface in surface-local coordinates, not to the toplevel.
- **lunette-v1.AC4.5 Success:** Text copied on the host pastes into a lunette client and text copied in a lunette client pastes on the host, for both the clipboard and the primary selection.

---

## Facts established by investigation

### smithay 0.7 supports multi-seat cleanly

`SeatState<D>` is `{ seats: Vec<Seat<D>> }` (`src/input/mod.rs:168-170`). `new_wl_seat(&mut self, display, name)` (`src/wayland/seat/mod.rs:167`) creates an independent `wl_seat` global per call. `Seat<D>` is `Arc<SeatRc<D>>` (`:186-188`), cloneable, with `WeakSeat`/`downgrade`/`upgrade` (`:195-205`), `Hash` and `Eq` (`:222-231`) so seats work as map keys, and `user_data() -> &UserDataMap` (`:342`). Capabilities are per-seat: `add_pointer`/`get_pointer`/`remove_pointer` (`:429`, `:446`, `:454`), `add_keyboard`/`get_keyboard`/`remove_keyboard` (`:561`, `:583`, `:591`), `name()` (`:675`).

`SeatHandler` is **per-compositor, not per-seat** (`src/input/mod.rs:145-165`). One impl on the application state, with the seat arriving as an argument to `focus_changed(&mut self, seat, ...)`, `cursor_image(&mut self, seat, image)`, and `led_state_changed(&mut self, seat, led_state)`. The discipline is therefore simple: never ignore the `seat` parameter.

Two subsystems are already per-seat and need no work:

- **Selections.** `set_data_device_focus(dh, seat, client)`, `set_data_device_selection(dh, seat, mimes, data)`, `current_data_device_selection_userdata(seat)`, and `clear_data_device_selection(dh, seat)` (`src/wayland/selection/data_device/mod.rs:244`, `:264`, `:343`, `:364`), with primary-selection mirrors at `.../primary_selection/mod.rs:158`, `:178`, `:256`, `:277`. Storage lives in `Seat::user_data()`. A `zwlr_data_control` client picks its own seat through `get_data_device { seat }` (`wlr_data_control/mod.rs:198-231`).
- **Popup grabs.** `PopupManager::grab_popup<D>(root, popup, seat, serial)` (`src/desktop/wayland/popup/manager.rs:58-64`), whose comment at `:99-101` states the seat is the primary store, via `seat.user_data().insert_if_missing(PopupGrabInner::default)`. `PopupManager` itself is shared and tracks only the popup tree plus a grab cleanup list, so the single instance from Phase 2 stays correct.

`docs/input.md:41` cautions about per-seat popup grabs. The caution is right and the library already handles it.

The one genuinely shared item is `SelectionHandler::SelectionUserData`, a single associated type for the whole compositor (`comp.rs:363`) — meaning one representation of selection data across all seats, which is fine.

### WayVR's single-seat assumptions

One seat, named `"wayvr"`, created at `mod.rs:184-188`, with one keyboard and one pointer added at `:261-263`. The assumptions are localised:

- `Application.cursor_image: CursorImageStatus` (`comp.rs:93`), written by `SeatHandler::cursor_image` (`comp.rs:341-343`) which **ignores its `seat` argument**. This is the clearest break under multi-seat. Natural fix: store it in `Seat::user_data()`.
- `WayVRCompositor.seat_keyboard` and `seat_pointer` held by value (`client.rs:39-40`, constructed `:96-97`). Every input method is hardcoded to them: `send_key` (`:229`), `release_all_keys` (`:247`), `set_keymap` (`:262`), `send_mouse_move` (`:289`), `send_pointer_button` (`:326`), the axis methods (`:372`, `:408`).
- `cur_modifiers: u8` (`mod.rs:142`), one global modifier shadow.
- `WindowManager { mouse, keyboard_focus }` (`window.rs:116-119`), one hover and focus pair for the whole compositor.
- `is_grabbed()` (`mod.rs:763`) and `set_focus` (`mod.rs:1136`, `:1171`) are compositor-wide.

One `SerialCounter` (`client.rs:41`) is shared between keyboard and pointer. Serials are effectively global in smithay, so sharing across seats is correct — it just needs moving out of the per-seat struct rather than duplicating.

Note `mod.rs:1128-1148`: keyboard focus is driven implicitly by pointer motion. With two seats that heuristic becomes per-seat policy, and by the mechanism-in-Rust rule it belongs in Lua rather than being reimplemented natively.

`docs/input.md:30` names the limitation directly — "WayVR sidesteps this with a single seat, where the pointer last used to click takes precedence" — and the investigation confirms it.

### libxkbcommon is not thread-safe, and that shapes `typeText`

smithay refuses an `xkb::Keymap` at its API boundary and takes a `String`, recompiling it inside its own context. `KeyboardHandle::set_keymap_from_string(&self, data: &mut D, keymap: String)` (`src/input/keyboard/mod.rs:810-825`) says so in a comment at `:814-815`. WayVR echoes it at `client.rs:263`: "Smithay only accepts keymaps in a string form due to thread safety concerns."

Two consequences for `typeText`:

1. The temporary keymap must be serialised to a string and recompiled by smithay. A `Keymap` built elsewhere cannot be handed over, and an `xkb::Context` must not be shared across threads.
2. **`KeyboardHandle` exposes no way to read the current keymap back as a string** — only `with_xkb_state(data, |XkbContext|)` (`:843`). So the previous keymap string must be cached before uploading a temporary one, or it cannot be restored. AC4.3 requires restoration explicitly.

Related API: `set_xkb_config` (`:827`), `modifier_state() -> ModifiersState` (`:1088`, `:1260`). `xkbcommon` is `0.8.0` in both WayVR and smithay (`smithay/Cargo.toml:403-405`, features `["wayland"]`), so there is no dual-version hazard — Phase 2's pin already accounts for this.

### `typeText` and reverse lookup are entirely new

Nothing in WayVR generates a keymap for arbitrary text, and nothing saves or restores one. What exists is forward-only and for rendering key legends: `XkbKeymap::label_for_key` (`subsystem/hid/mod.rs:344-357`, via `xkb::State::new` and `key_get_utf8`) and an AltGr probe (`:359-386`).

`docs/input.md:52` asks for "keysym-for-keycode-under-modifiers, the layout list, and reverse `keysym → (keycode, modifiers)` lookup". Only the forward direction exists. The reverse lookup is new, and it is what makes `typeText` possible: build it by enumerating keycodes across modifier combinations and inverting the resulting map.

The technique at `docs/input.md:58-62` — synthesise a keymap mapping spare keycodes to the required keysyms, upload it, drive key events, restore — must be built from scratch.

### Modifiers are faked as keycodes

`set_modifiers` (`mod.rs:1215-1226`) diffs an old and new `u8` bitmask and synthesises press and release of a representative key per bit through a `MODS_TO_KEYS` table. There is no direct modifier injection.

Smithay owns the authoritative `ModifiersState` inside `KbdInternal`, updated by `KeyboardHandle::input`. WayVR's parallel `cur_modifiers` is a shadow of it. `docs/input.md:51` asks for "explicit modifier state", which means driving smithay's state through `with_xkb_state` rather than faking keypresses. That is new.

Key events go through `client.rs:229-245`: `seat_keyboard.input(..., Keycode::new(virtual_key), state, serial, time, |_,_,_| FilterResult::Forward)`. The filter always forwards, so the compositor never intercepts a binding — correct for lunette, where binding policy is Lua's.

Key repeat is set at seat construction (`mod.rs:262`, delay 200, rate 50). `docs/input.md:56` moves it to Lua, so `add_keyboard` takes a policy-supplied value.

### `hit_test.rs` sheds most of its bulk

406 lines, of which lunette wants perhaps half.

The algorithm (`hit_target`, `:139-174`) is sound and ports directly: **popups are checked first**, before the client-area bounds test, because a popup may extend outside the toplevel (comment at `:143`). Then surfaces are iterated **in reverse** (`:158`, top-most last) taking the first that accepts input, with a clamped fallback to the toplevel (`:170-173`).

Subsurface walking is `collect_rendered_surface_tree_at` (`:186-227`), accumulating `surface_location` (`:177-184`, reading `SubsurfaceCachedState.location` when the role is subsurface). It deliberately does not prune buffer-less parents (`:199`), since children may still have buffers. Surface-local coordinates are `global_pos - surface.pos` (`:234`, `:307`).

Input-region testing has two variants that differ meaningfully. `surface_accepts_input` (`:233-253`) bounds-checks against size then consults `SurfaceAttributes.input_region`, with `None` meaning the whole surface. `surface_accepts_input_states` (`:255-282`) lets an explicit input region win even with no buffer (`:269-271`), falling back to buffer extent otherwise (`:274-279`). `surface_tree_input_hit_test` (`:284-318`) relies on bottom-to-top traversal so later hits overwrite earlier ones (`:310`).

**Two couplings to remove:**

1. `RenderedSurface.image: Arc<vulkano::image::view::ImageView>` (`:15`, `:36`), read at `:210-219`, `:274-278`, and `:329`. **Only the size is ever used for hit-testing** — the handle rides along purely so the renderer can reuse the struct. Split `RenderedSurface` into a geometry-only hit-test type and a separate render list. This is what keeps `lunette-compositor` free of a GPU dependency, which AC9.4 depends on.
2. `PointerHit` from `crate::backend::input` (`:19`, defined `backend/input.rs:358-364` as `{ pointer, overlay: OverlayID, mode: PointerMode, primary, uv }`), appearing in `WvrHitTarget::Panel` (`:43`) and in `transformed_uv_from_hit`/`panel_hit_from_hit`/`hit_target` (`:79`, `:95-103`, `:139`). This drags XR overlay identity and pointer modes into the compositor.

Under `docs/input.md:5-7` — "The native layer's primitive is a pixel-space event sink. The Rust code has no knowledge of the 3D scene" — Lua supplies pixel coordinates directly. So the whole `PointerHit`, UV, `mouse_transform`, and panel layer disappears. lunette wants `hit_target_at(client_pos: Vec2)` (`:105`) without the `mouse_transform` inverse at `:106-109`.

Do not port `BORDER_SIZE` (`:23`) or `BAR_SIZE` (`:24`). Those are WayVR's titlebar chrome constants; lunette's chrome is mullion's, in Lua.

`build_hit_context` (`:356`) takes an unused `_popup_manager` (`:358`) and instead uses the static `PopupManager::popups_for_surface` (`:369`). It skips unconfigured popups by reading `XdgPopupSurfaceData.configured` (`:370-382`) and computes `popup_origin = point - popup.geometry().loc` (`:384`). Both details matter and should survive the port.

`WvrHitContext` holds `Rc<[RenderedSurface]>` and `Rc<[PopupRoot]>` (`:60-61`), and `collect_rendered_surface_tree` returns `Rc<[…]>` (`:229`) — three sites, as recorded in Phase 2. These become `Arc<[…]>`.

### Clipboard is barely started

WayVR binds all four protocols (`mod.rs:186-199`, delegates at `comp.rs:680-694`): `wl_data_device`, primary selection, `ext_data_control`, and `zwlr_data_control`, the last two with a `filter_allow_any` predicate admitting every client (`mod.rs:176-178`). Handler impls exist at `comp.rs:356`, `:621`, `:627`, `:633`, `:362-392`.

What it actually does is much less than that suggests.

`set_clipboard_text` (`comp.rs:102-109`) hardcodes two MIME types, `"text/plain;charset=utf-8"` and `"text/plain"`, with `SelectionUserData = Arc<[u8]>` (`:363`). There is no format negotiation.

`send_selection` (`:365-383`) spawns a **detached thread per request**, clearing `O_NONBLOCK` with `fcntl_setfl` (`:376`, commented as necessary or `write_all` stops halfway) and writing the bytes. No join, no bound on concurrent threads, no cancellation — a client requesting the selection repeatedly spawns threads without limit. It is sound, capturing only an `Arc<[u8]>` and the `OwnedFd`, but it violates the project's rule against unbounded concurrency.

**`new_selection` is empty** (`:385-391`). WayVR never observes a client setting a selection, so there is **no client-to-host path at all**. `current_data_device_selection_userdata` and `request_data_device_client_selection` are never called anywhere in the tree.

Primary selection is never set in either direction — `set_primary_selection` (`primary_selection/mod.rs:178`) has no caller, and `set_primary_focus` (`comp.rs:338`) is the only primary wiring.

The `ClipboardProvider` trait has exactly one method, `set_clipboard_utf8(&mut self, content: &str)` (`subsystem/clipboard/mod.rs:6-8`), implemented for Wayland (`clipboard/wl.rs:88-90`, over ext-data-control on a dedicated worker thread, `:70-73`, `run_worker` `:100`) and X11 (`clipboard/x11.rs:38-40`). **Both are write-only.** The sole caller of `set_clipboard` (`mod.rs:1228-1230`) is the speech-to-text overlay (`overlays/whisper.rs:59`), which separately also writes the host clipboard (`:64-65`).

So WayVR does not bridge. It has one direction, for one clipboard, of one MIME type, and it is one overlay writing the same string to two unrelated sinks. What ports is the `send_selection` fd-writing pattern and the protocol bind list. Roughly four fifths of this phase's clipboard scope is new.

### The seat-to-host clipboard mapping was unspecified

`docs/input.md` never mentions clipboard. Its only adjacent reference is `:43`, pointing at `host-desktop.md#the-input-domain-leak` for the single-host-seat constraint.

With one seat per hand, each seat owns a clipboard and a primary selection, while the host has exactly one of each. Decided on 2026-08-06: **one designated bridge seat.** A single seat is bridged to the host; other seats keep independent selections that stay inside lunette. Lua chooses which seat is bridged, so the policy stays out of Rust. Task 7 records this in `docs/decisions.md` and `docs/input.md`.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: Multiple seats

**Verifies:** `lunette-v1.AC4.1`.

**Files:**
- Create: `crates/lunette-compositor/src/seat.rs`
- Modify: `crates/lunette-compositor/src/state.rs`, `src/client.rs`, `src/window.rs`

**Step 1: Key seats by handle**

Replace the by-value `seat_keyboard` and `seat_pointer` (`client.rs:39-40`) with a keyed collection of seat bundles, each holding its `Seat<State>`, keyboard handle, and pointer handle. `Seat<D>` is `Hash + Eq` (`input/mod.rs:222-231`), so it can be the key directly, but prefer a `SeatId` newtype so the identifier crossing the thread protocol carries no smithay type.

Every input command from Phase 2's protocol already carries a `SeatId`. Route on it.

**Step 2: Move per-seat state into `Seat::user_data()`**

`Application.cursor_image` (`comp.rs:93`) is compositor-global and its handler ignores the seat argument (`comp.rs:341-343`). Store the cursor image in `Seat::user_data()` instead, keyed per seat.

Do the same for the hover and focus pair currently in `WindowManager` (`window.rs:116-119`) and for the modifier shadow at `mod.rs:142`.

**The discipline: never ignore the `seat` argument in a `SeatHandler` method.** `SeatHandler` is per-compositor with the seat passed in (`input/mod.rs:145-165`), so every ignored parameter is a latent multi-seat bug. Note it in the impl.

**Step 3: Keep one `SerialCounter`**

Serials are effectively global in smithay, so the shared counter at `client.rs:41` is correct. Move it out of the per-seat struct rather than giving each seat its own — per-seat counters would produce colliding serials.

**Step 4: `lunette.newSeat`**

`docs/input.md:26-41` specifies the API. Each seat gets independent pointer position, focus, and keyboard state.

The collapse-to-one-seat mode at `:39` is Lua policy over this primitive, not a native mode. Similarly, WayVR's implicit focus-follows-pointer heuristic (`mod.rs:1128-1148`) does not port: focus policy is Lua's, and Rust only applies what Lua asks for.

**Step 5: Test**

Two seats over the socketpair harness: each hovers a different window; each has its own pointer position; focus on one does not disturb the other; a modifier held on one seat does not appear on the other; removing a seat leaves the other functional.

**Verification:** `cargo test -p lunette-compositor`

**Step 6: Commit**

```bash
git add crates/lunette-compositor/src/
git commit -m "feat(compositor): support one wayland seat per hand"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Port `hit_test.rs`

**Verifies:** `lunette-v1.AC4.4`.

**Files:**
- Create: `crates/lunette-compositor/src/hit_test.rs`

**Step 1: Strip the couplings**

Split `RenderedSurface` (`hit_test.rs:33-39`). Hit-testing needs `surface`, `surface_id`, `pos`, and `size` — it reads `image` only to obtain the size (`:210-219`, `:274-278`, `:329`). The GPU handle belongs to a separate render list.

This is not cosmetic. `lunette-compositor` must not depend on a GPU crate, or AC9.4's GPU-free test suite becomes impossible, and `CONTRIBUTING.md:32` states the rule.

Drop `PointerHit` (`:19`) entirely, along with `WvrHitTarget::Panel` (`:43`), `transformed_uv_from_hit` (`:79`), `panel_hit_from_hit` (`:95`), `mouse_transform`, and `uv_range`. Under `docs/input.md:5-7` Lua supplies pixel coordinates, so the UV and panel layer has no purpose. Keep `hit_target_at(client_pos)` (`:105`) without the `mouse_transform` inverse at `:106-109`.

Do not port `BORDER_SIZE` (`:23`) or `BAR_SIZE` (`:24`) — WayVR titlebar chrome, replaced by mullion in Phase 6.

Change the three `Rc<[…]>` sites to `Arc<[…]>`: `:60`, `:61`, and the return type at `:229`.

**Step 2: Preserve the algorithm**

Three details are load-bearing and easy to lose:

- **Popups are tested before the client-area bounds check** (`:143`), because a popup may extend beyond its toplevel. Reversing this breaks AC4.4 for exactly the menus that motivate it.
- **Surfaces iterate in reverse** (`:158`), top-most last, taking the first that accepts input.
- **`surface_tree_input_hit_test` relies on bottom-to-top traversal** so later hits overwrite earlier ones (`:310`).

**Step 3: Preserve the input-region subtleties**

Two variants differ deliberately. `surface_accepts_input` (`:233-253`) bounds-checks then consults `SurfaceAttributes.input_region`, `None` meaning the whole surface. `surface_accepts_input_states` (`:255-282`) lets an explicit input region win even with no buffer (`:269-271`), falling back to buffer extent otherwise (`:274-279`). Keep both; the difference is why a buffer-less surface with an input region still receives clicks.

Keep `collect_rendered_surface_tree_at`'s refusal to prune buffer-less parents (`:199`) — children may still have buffers.

**Step 4: Preserve the popup context details**

`build_hit_context` (`:356`) skips unconfigured popups by reading `XdgPopupSurfaceData.configured` (`:370-382`), and computes `popup_origin = point - popup.geometry().loc` (`:384`). Both survive. It also takes an unused `_popup_manager` parameter (`:358`) and uses the static `PopupManager::popups_for_surface` (`:369`) — drop the dead parameter.

**Step 5: Provenance**

Provenance header per Phase 2 Task 1, naming the upstream path and commit.

**Step 6: Test**

Pure geometry over synthetic surface trees, no GPU and no client. Cover: a click inside a popup that overlaps the toplevel goes to the popup in surface-local coordinates (AC4.4); a click outside every popup goes to the toplevel; a subsurface offset by `SubsurfaceCachedState.location` receives correctly translated coordinates; a surface with an empty input region is skipped and the surface beneath receives; a buffer-less surface with an explicit input region still receives; an unconfigured popup is ignored; overlapping surfaces resolve top-most-first.

**Verification:** `cargo test -p lunette-compositor`

**Step 7: Commit**

```bash
git add crates/lunette-compositor/src/hit_test.rs
git commit -m "feat(compositor): route input to popups and subsurfaces"
```
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 3-5) -->
<!-- START_TASK_3 -->
### Task 3: Keymaps and modifier state

**Verifies:** `lunette-v1.AC4.2`.

**Files:**
- Create: `crates/lunette-compositor/src/keymap.rs`

**Step 1: Upload as a string, and cache it**

`KeyboardHandle::set_keymap_from_string(&self, data, keymap: String)` (`input/keyboard/mod.rs:810-825`) is the only upload path, and it takes a `String` because **libxkbcommon is not thread-safe** — smithay recompiles inside its own context and says so at `:814-815`.

Cache the current keymap string per seat when uploading. `KeyboardHandle` offers no way to read it back — only `with_xkb_state` (`:843`) — so without the cache Task 5 cannot restore it, and AC4.3 requires restoration.

**Step 2: Real modifier state**

Do not port `set_modifiers` (`mod.rs:1215-1226`), which diffs a `u8` bitmask and synthesises a representative keypress per bit through `MODS_TO_KEYS`. `docs/input.md:51` asks for explicit modifier state; drive smithay's authoritative `ModifiersState` through `with_xkb_state` instead. Faking modifiers as keypresses misreports state to clients that query it and produces spurious key events.

**Step 3: Key events**

`KeyboardHandle::input` with a filter that always forwards, as WayVR does (`client.rs:229-245`). The compositor never intercepts a binding; binding policy is Lua's.

**Step 4: Key repeat from Lua**

WayVR fixes repeat at seat construction (`mod.rs:262`, delay 200, rate 50). `docs/input.md:56` moves it to Lua, so `add_keyboard` takes a policy-supplied value with a documented default.

**Step 5: Expose the keymap for querying**

`docs/input.md:50-52` requires keysym-for-keycode-under-modifiers, the layout list, and reverse `keysym → (keycode, modifiers)` lookup.

WayVR has only forward lookup, and only for rendering key legends (`subsystem/hid/mod.rs:344-357`). Build the reverse map by enumerating keycodes across modifier combinations and inverting the result. Task 5 depends on it.

Build it once per keymap and cache it; enumerating on every query is wasteful and the keymap changes rarely.

**Step 6: Test**

Keymap parsing and reverse-lookup construction are pure over keymap strings. Cover: a keycode with a modifier produces the character the layout defines (AC4.2); reverse lookup round-trips for every keysym the layout can express; a keysym the layout cannot express is absent rather than mapped wrongly; modifier state updates are visible to a client.

**Verification:** `cargo test -p lunette-compositor`

**Step 7: Commit**

```bash
git add crates/lunette-compositor/src/keymap.rs
git commit -m "feat(compositor): handle keymaps and explicit modifier state"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Expose keymap data to Lua

**Verifies:** `lunette-v1.AC4.2`, and `lunette-v1.AC3.3` — which phase 4 did not deliver.

Phase 4 built the host provider chain's keyboard half and reached none of it: `Sink` exposes `pointer` and `button` only, so nothing calls `send_key`, `set_modifiers`, or `set_keymap`. `sink:key` below is what makes AC3.3 reachable, and it must route to the host provider for a host sink exactly as `sink:pointer` does. The same step unblocks `wl_virtual`, which `hid::open` leaves unconfigured until a keymap exists: `zwp_virtual_keyboard_v1` treats a key before a keymap as a protocol error, so the provider would be disconnected by its first keystroke.

**Files:**
- Modify: `crates/lunette/src/lua/sink.rs`
- Modify: `docs/lua-api.md`

**Step 1: The surface**

`sink:key(keycode, pressed)`, explicit modifier state, the layout list, forward lookup, and reverse lookup, per `docs/input.md:50-52`. `docs/input.md` describes these but names none of them, so give each a concrete name here.

The reverse lookup is what lets mullion's virtual keyboard in Phase 6 render correct legends and produce correct keycodes without reimplementing xkb in Lua.

**Two further sink methods, neither currently documented anywhere in `docs/`:**

- **`sink:scroll(dx, dy)`.** The documented sink surface is pointer, button, key, and `typeText` only. Tier 2 of the standard library requires scroll (`docs/stdlib.md:17`), and the compositor already has the plumbing — WayVR's `send_pointer_axis_wheel_raw` and `send_pointer_axis_wheel_accumulated` (`client.rs:372`, `:408`). Expose both the raw and accumulated forms, since discrete and smooth scroll sources differ and collapsing them loses information clients use.
- **A hover-versus-focus primitive.** Tier 2 needs hover feedback distinct from focus, and it is currently unclear whether focus is implied by `sink:pointer`. Make it explicit: entering and leaving a sink is a separate operation from moving within it, so Lua can highlight a hovered panel without stealing focus from another. Being implicit here would force mullion to infer focus from pointer motion, which is exactly the heuristic Task 1 removes from the compositor.

All of these are API defects under `CONTRIBUTING.md:62` — mullion may use only the public API, and it cannot be written without them.

**Step 2: Update the documentation**

`docs/lua-api.md` is normative and this adds surface to it. Update it in the same change, per `CONTRIBUTING.md`.

**Step 3: Test**

The snapshot-to-Lua conversion with a Lua state and no GPU: the layout list is readable; forward lookup matches the keymap; reverse lookup returns keycode and modifier pairs Lua can feed back into `sink:key`.

**Verification:** `cargo test -p lunette`

**Step 4: Commit**

```bash
git add crates/lunette/src/lua/sink.rs docs/lua-api.md
git commit -m "feat: expose keymap queries to lua"
```
<!-- END_TASK_4 -->

<!-- START_TASK_5 -->
### Task 5: `Sink:typeText`

**Verifies:** `lunette-v1.AC4.3`.

**Files:**
- Create: `crates/lunette-compositor/src/type_text.rs`

Entirely new work. Nothing in WayVR generates a keymap for arbitrary text or saves and restores one.

**Step 1: Decide what needs synthesising**

For the requested text, resolve each character to a keysym, then use Task 3's reverse lookup to find those the active layout can already express. Only the remainder needs a temporary keymap.

Text the active layout can express entirely should take the ordinary path and upload nothing. `docs/input.md:58-62` frames the temporary keymap as the technique for what the layout cannot express, not as the default.

**Step 2: Chunk to fit the spare keycode range**

Decided on 2026-08-06: when the text needs more distinct keysyms than the spare keycode range holds, **split it into runs that fit and repeat the cycle per chunk**, rather than failing.

Each chunk uploads a keymap, drives its key events, and the last chunk restores. Clients see several keymap changes, which is acceptable and correct — a `wl_keyboard.keymap` event mid-typing is legal.

**Step 3: The cycle**

Per chunk: cache the current keymap string (Task 3), synthesise a keymap mapping spare keycodes to the required keysyms, serialise it to a string, `set_keymap_from_string`, drive press and release per character, then restore the cached string.

Restore even when a chunk fails. A client left with lunette's synthetic keymap has a broken keyboard, and AC4.3 requires the client's own handling to be restored afterwards. This is the one place in the phase where a failure path must not simply propagate.

**Step 4: Serial and timing**

Each synthetic key event needs a serial from the shared counter and a timestamp from the monotonic baseline established in Phase 2 Task 6. Do not reuse a serial across events.

**Step 5: Test**

Chunking and keysym resolution are pure. Cover: text the layout expresses uploads no keymap; text it cannot triggers exactly one upload and one restore; text needing more keysyms than one keymap holds produces the expected number of chunks; a simulated failure mid-chunk still restores; the emitted key event sequence matches the text.

End to end over the socketpair harness: a test client receives the expected characters, and its keymap after typing equals its keymap before.

**Verification:** `cargo test -p lunette-compositor`

**Step 6: Commit**

```bash
git add crates/lunette-compositor/src/type_text.rs
git commit -m "feat(compositor): type text the active layout cannot express"
```
<!-- END_TASK_5 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (tasks 6-7) -->
<!-- START_TASK_6 -->
### Task 6: Clipboard, both directions and both selections

**Verifies:** `lunette-v1.AC4.5`.

**Files:**
- Create: `crates/lunette-compositor/src/selection/mod.rs`, `host.rs`
- Modify: `crates/lunette-compositor/src/state.rs`

Roughly four fifths of this is new. WayVR binds the protocols but implements one direction, for one selection, of one MIME type.

**Step 1: Implement `new_selection`**

`comp.rs:385-391` is **empty**, which is why there is no client-to-host path at all. Implementing it is what makes half of AC4.5 possible.

On a client setting a selection, record the offered MIME types and push the selection to the host through the data-control provider.

**Step 2: Read from the host**

`ClipboardProvider` (`subsystem/clipboard/mod.rs:6-8`) has one method, `set_clipboard_utf8` — write-only, in both its Wayland and X11 implementations. Add a read and a watch counterpart.

The Wayland implementation already runs its own connection on a worker thread communicating over a `calloop` channel (`clipboard/wl.rs:70-73`, `run_worker` `:100`). That is the right seam to extend, and it matches the project's message-passing preference. A host clipboard read must never block the frame thread.

**Step 3: Primary selection, both ways**

Never wired in WayVR: `set_primary_selection` (`primary_selection/mod.rs:178`) has no caller, and `set_primary_focus` (`comp.rs:338`) is the only primary wiring. AC4.5 requires both selections in both directions, so this is symmetric new work alongside the regular selection.

**Step 4: Real format negotiation**

`set_clipboard_text` hardcodes `"text/plain;charset=utf-8"` and `"text/plain"` (`comp.rs:102-109`). Offer the MIME types the source actually advertises and negotiate on request.

Negotiation stays in Rust, as the design specifies. Where a type genuinely cannot be represented, fail the transfer with an error rather than silently substituting — dropping content you cannot represent is a correctness bug, not a convenience.

**Step 5: Bound the transfer concurrency**

`send_selection` (`comp.rs:365-383`) spawns a **detached thread per request** with no join, no bound, and no cancellation. A client requesting repeatedly spawns threads without limit.

Replace it with a worker over a bounded queue. Keep the `fcntl_setfl` clearing of `O_NONBLOCK` (`:376`) — its comment records that `write_all` otherwise stops halfway, which is a real bug someone will otherwise reintroduce.

**Step 6: Test**

Format negotiation and the transfer state machine are pure. Cover: a client setting a selection produces an offer to the host; a host selection is offered to clients; primary selection works in both directions independently of the regular one; a MIME type the target cannot represent fails rather than substituting; the transfer queue bounds concurrency; a client disconnecting mid-transfer does not leak a worker.

End to end over the socketpair harness with a fake host provider, in both directions and for both selections.

**Verification:** `cargo test -p lunette-compositor`

**Step 7: Commit**

```bash
git add crates/lunette-compositor/src/selection/
git commit -m "feat(compositor): bridge clipboard and primary selection both ways"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: The designated bridge seat

**Verifies:** `lunette-v1.AC4.5`.

**Files:**
- Modify: `crates/lunette-compositor/src/selection/mod.rs`
- Modify: `docs/input.md`, `docs/decisions.md`

**Step 1: The mapping**

With one seat per hand, each seat owns a clipboard and a primary selection, while the host has exactly one of each. `docs/input.md` never addresses this; its only adjacent note is `:43`.

Decided on 2026-08-06: **one designated bridge seat.** Exactly one seat is bridged to the host in both directions. Other seats keep independent selections that stay inside lunette. Lua chooses which seat is bridged, so policy stays out of Rust.

**Step 2: Behaviour**

A host selection is offered to the bridge seat. A selection set on the bridge seat is pushed to the host. A selection set on any other seat is visible to clients focused on that seat and is not pushed.

Changing the bridge seat takes effect at the next frame boundary, like every other mutation.

**Step 3: Document it**

Add the mapping to `docs/input.md`, which is normative and currently silent on clipboard. Add a paragraph to `docs/decisions.md` recording the decision and the reasoning: last-writer-wins across seats races on two hands copying in quick succession, and the winner is timing-dependent.

**Step 4: Test**

The bridge seat receives host selections and pushes its own; a non-bridge seat does neither; reassigning the bridge seat moves both behaviours at a frame boundary; two seats holding different selections do not interfere.

**Verification:** `cargo test -p lunette-compositor`

**Step 5: Commit**

```bash
git add crates/lunette-compositor/src/selection/mod.rs docs/
git commit -m "feat(compositor): bridge one designated seat to the host clipboard"
```
<!-- END_TASK_7 -->
<!-- END_SUBCOMPONENT_C -->

<!-- START_TASK_8 -->
### Task 8: Check suite and human gates

**Verifies:** All Phase 5 criteria.

**Step 1: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 2: Confirm the crate boundary still holds**

Run: `cargo tree -p lunette-compositor`
Expected: no `lunette-lovr` and no GPU crate. Task 2 removed a vulkano type from the hit-test path; this confirms nothing replaced it.

Run: `cargo test -p lunette-compositor` with no Vulkan ICD visible.
Expected: passes (AC9.4).

**Step 3: The human gates**

- Two hands hover two different windows simultaneously, each with its own cursor (AC4.1).
- Typing reaches the focused sink with the correct layout (AC4.2).
- `typeText` enters text the layout cannot express, and the client's keyboard works normally afterwards (AC4.3).
- A popup menu receives clicks at the right coordinates (AC4.4).
- Text copied on the host pastes into a lunette terminal, and text copied there pastes on the host, for both the clipboard and the middle-click primary selection (AC4.5).

**Step 4: Commit**

Only if the check suite produced changes.
<!-- END_TASK_8 -->

---

## Done when

- Two seats hover different windows simultaneously with independent pointer position, focus, and modifier state.
- Typing reaches the focused sink with the layout's own characters.
- `typeText` enters text the layout cannot express and restores the client's keymap afterwards.
- A popup menu receives clicks in surface-local coordinates.
- Both clipboards bridge both directions through the designated seat.
- `lunette-compositor` still has no GPU dependency and its tests pass without one.
- All five check commands pass.

## Deliberately not in this phase

- Focus policy. WayVR's focus-follows-pointer heuristic (`mod.rs:1128-1148`) does not port; focus is Lua's decision over the native primitive.
- The collapse-to-one-seat mode (`docs/input.md:39`), which is Lua policy over this phase's multi-seat primitive.
- Panel chrome. `BORDER_SIZE` and `BAR_SIZE` (`hit_test.rs:23-24`) are WayVR's titlebar; mullion owns chrome in Phase 6.
- The virtual keyboard, which consumes this phase's keymap queries — Phase 6.
- Drag and drop (`host-desktop.md:66`).
- IME, recorded as out of scope in the design.
