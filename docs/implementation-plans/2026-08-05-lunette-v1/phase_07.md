# lunette v1 Implementation Plan — Phase 7: Reload, lunctl, and error handling

**Goal:** In-headset iteration without losing running applications, and external control.

**Architecture:** Soft reload discards the Lua state while everything native keeps running. Restart discards the Lua state *and* the Vulkan device, which requires an explicit two-phase quiesce with the compositor thread so imported images are destroyed before LÖVR destroys the device under them. A control thread accepts Lua chunks on a Unix socket and hands them to the main thread to evaluate between frames, under a best-effort time budget.

**Tech Stack:** LÖVR's `lovr.event.restart` and restart cookie, LuaJIT `debug.sethook` with `jit.off`, `std::os::unix::net::UnixListener`.

**Scope:** Phase 7 of 8. Specified at intent level in the design; task detail derives from investigation.

**Codebase verified:** 2026-08-06.

---

## Acceptance criteria coverage

### lunette-v1.AC5: Arrangement is scripted, and iteration is fast
- **lunette-v1.AC5.4 Success:** `lunette.reload()` applies an edited layout without disconnecting any client, and teardown hooks run so timers and signal connections do not accumulate.
- **lunette-v1.AC5.5 Success:** `lunette.restart()` rebuilds the Lua state and the XR session while clients stay connected.

### lunette-v1.AC8: The session is controllable and survivable
- **lunette-v1.AC8.1 Success:** `lunctl` evaluates a chunk between frames and returns nested tables, with handles serialised as opaque ids.
- **lunette-v1.AC8.2 Failure:** A chunk that exceeds the wall-clock budget is abandoned with an error rather than stalling the frame loop indefinitely; the socket is created mode 0600 and never listens on a network address.
- **lunette-v1.AC8.3 Failure:** An error raised in a user callback is caught, reported through `lovr.lunerror` and an error panel, and the session continues; identical errors repeating each frame are rate-limited.
- **lunette-v1.AC8.4 Failure:** A `main.lua` that fails to load produces safe mode with a laser, a panel, and a reload key, not a black headset.

**AC8.2's first clause is restated by Task 6.** The wall-clock budget cannot be enforced strictly under LuaJIT. See the investigation notes.

---

## Facts established by investigation

### Restart destroys the Vulkan device

This is the phase's hardest fact and the design does not mention it.

`lovr.event.restart()` (`l_event.c:187`) pushes `EVENT_RESTART`. `boot.lua:196` returns `'restart'` plus the value of the user's `lovr.restart` callback as a cookie. The coroutine terminates with that pair (`boot.lua:372-374`), and `main.c:18` recognises it and returns `false` from the step rather than exiting. Then `main.c:68-72` reads the cookie with `luax_checkvariant`, zeroes it if it is a LÖVR object, calls `luax_close(L)`, and breaks back to the `for(;;)` at `main.c:33`, which builds a fresh `luaL_newstate()`.

`luax_close` (`api.c:514-539`) drains tasks, calls `lua_close`, then runs the finalizer chain registered by `luax_atexit`. That chain includes:

- `lovrGraphicsDestroy` (`l_graphics.c:437`), ending in `gpu_destroy()` (`graphics.c:955`), which does `vkDeviceWaitIdle`, `vkDestroyDevice`, and `vkDestroyInstance` (`gpu_vk.c:3645`, `:3679`, `:3682`).
- `lovrHeadsetDestroy` (`l_headset.c:1177`, impl `headset.c:384`), which destroys swapchains, then `xrDestroySession` (`headset.c:1289`) and `xrDestroyInstance` (`:3580`).

So every dmabuf-imported `VkImage` and every `VkDeviceMemory` the compositor thread owns becomes a dangling handle, and `vkDestroyDevice` will abort or leak if they are still live. Phase 2 Task 10 established that lunette owns those objects, not LÖVR — `gpu_texture_destroy` returns early on `imported`.

**AC5.5 is still achievable**, because the compositor never speaks Vulkan to its clients. It imports fds. The Wayland socket, the client connections, and the `wl_buffer` state all live in Rust, outside the Lua state, and are untouched by any of this. `docs/architecture.md:58` records the enabling rule: Rust holds no long-lived references into Lua.

What it needs is an explicit two-phase teardown across the thread boundary, decided on 2026-08-06 and built in Tasks 3 and 4. `docs/lovr-integration.md:74` says "imported textures die and re-import", which is correct but reads as a passive consequence rather than a protocol that must be driven.

**Ordering matters.** lunette's teardown must run *before* `luax_close`, driven from `lovr.restart` or immediately before the step function returns `'restart'`. Registering it as another `luax_atexit` finalizer would be wrong: the chain is a linked list with no ordering guarantee relative to graphics, and `graphics.c:891-894` carries LÖVR's own comment that the headset-versus-graphics teardown ordering "is really hacky". Do not add to that.

`os_init()` is outside the restart loop (`main.c:31`), so the OS layer survives. The simulator state is deliberately preserved (`headset.c:387`).

The cookie arrives in the new state as `arg.restart` (`main.c:40-42`). It is a single `Variant` (`util.h:206-216`), so nested tables survive as `TYPE_TABLE`, but LÖVR objects are zeroed at `main.c:69`.

### Reload must not clear `lovr.*`

`docs/lua-api.md:62`: reload "clears `package.loaded` for user and standard-library namespaces and re-runs `main.lua`. The LÖVR modules, XR session, GPU objects, compositor, and clients all remain running."

The scope is user and standard-library namespaces. Clearing `lovr.*` would make the next `require 'lovr.graphics'` re-run module initialisation against a live graphics module.

`docs/lua-api.md:64` names the hazards: "timers, signal connections, coroutines, and stashed handles", with mullion providing the teardown hook that soft reload calls — built in Phase 6 Task 4.

One hazard the specification does not name: `main.lua` defines the user's LÖVR callbacks (`docs/lua-api.md:18`), so a re-run that leaves a stale `lovr.draw` from a callback the user has since deleted keeps calling it. Reset the user callbacks as part of the clear.

### The chunk budget cannot be strict under LuaJIT

`debug.sethook(fn, "", N)` with a count hook is the standard way to bound an arbitrary chunk. Under LuaJIT it has a specific failure: **JIT-compiled code does not call debug hooks.** A trace in a tight loop never returns to the interpreter, so the hook never fires.

`jit.off` on the loaded chunk forces interpreter execution so the hook fires reliably, and is the right trade here — a control-plane chunk is not a hot path. The alternative, building LuaJIT with `-DLUAJIT_ENABLE_CHECKHOOK`, costs speed globally.

Even with `jit.off` the budget stays advisory:

- `error()` raised from a hook can be caught by a `pcall` inside the user's own chunk.
- A loop inside a C function, or a blocking FFI call, is uninterruptible by any hook.

Decided on 2026-08-06: **best-effort, documented honestly.** A hard bound would need a watchdog outside Lua, and since the chunk runs on the Lua thread the only thing a watchdog can do is abort the process — turning a bad `lunctl` command into a crash that takes every running client with it. That is worse than the failure it prevents.

AC8.2's first clause is restated accordingly in Task 6.

### The socket cannot be secured by `fchmod`

Three approaches, two of which are wrong:

- **`fchmod` on the listener fd does not work on Linux.** For a socket the fd refers to the socket object, not the filesystem inode. `fchmod` and `fchown` succeed and change nothing. Only path-based `chmod` affects the inode.
- **bind then `set_permissions`** leaves a window in which the socket is world-accessible, and a connection accepted in that window remains valid afterwards.
- **`umask`** is process-global and not thread-safe. Another thread creating a file concurrently gets the wrong mode.

The correct pattern is a private parent directory: create `$XDG_RUNTIME_DIR/lunette/`, set it to 0700, and bind inside it. The directory mode closes the race completely, because no other uid can traverse into it regardless of the socket's own mode. Then set 0600 on the socket as well, for defence in depth.

`UnixListener::bind` creates the inode with `0777 & ~umask` and offers no pre-creation hook, which is why the directory is doing the real work.

Validate `$XDG_RUNTIME_DIR`'s ownership and mode at startup rather than trusting it. The XDG specification mandates 0700 and user ownership, but a specification is not an enforcement. Per `CONTRIBUTING.md:110` a library never reads the environment — the binary reads it and passes the path in.

Unlink a stale socket only after confirming nothing is listening on it, or two instances silently steal each other's path.

### Custom events are narrow

`lovr.handlers = setmetatable({}, { __index = lovr })` at `boot.lua:345`, and the poll loop is `for name, a, b, c, d in lovr.event.poll() do` (`boot.lua:193`), dispatching at `:198` as `lovr.handlers[name](a, b, c, d)`.

Two limits follow:

- **Four payload arguments.** `docs/lua-api.md:42` states it: "boot.lua's poll loop unpacks four arguments, so richer payloads travel as a table."
- **Event names are capped at 31 characters plus a NUL** — `CustomEvent.name` is `char name[32]` (`event.h:102-106`). Every `lun*` name planned fits, but the limit is worth knowing before someone invents a longer one.

`'quit'` and `'restart'` are intercepted before dispatch and are reserved.

Native code pushes by building a `CustomEvent` and calling `lovrEventPush`, exactly as `l_event.c:162-179` does. `lovrEventPush` is the thread-safe entry point, so the compositor thread can push directly without marshalling through the main thread first.

### Serialisation pitfalls

Reference cycles recurse infinitely without a seen-set. Shared subtables get duplicated by a naive tree serialiser. Table and function keys have no stable representation. Mixed array and hash parts have no JSON equivalent. `nil` holes change `#t`. NaN and infinity, and integer-versus-float precision, need decided answers. `__index` and `__pairs` metamethods can hide or fabricate fields. Functions, coroutines, and userdata are unrepresentable outright.

`CONTRIBUTING.md` is explicit that silently dropping content you cannot represent is a correctness bug, not a convenience. So the serialiser **errors** on an unrepresentable value rather than falling back to `tostring` — which is precisely what `docs/lua-api.md:97` criticises awesome for.

LÖVR's own `luax_checkvariant` (`api.c:561`) handles nested tables to depth 128 with a cycle check at `:562`, which is a reasonable precedent for the caps.

Handles serialise as a tagged node carrying the Rust-side generational id that already backs them (`docs/architecture.md:48`). **Not `tostring(table)` addresses** — those are reused after collection, so an id could silently refer to a different object.

### awesome-client, for shape only

`utils/awesome-client` is a bash wrapper around `dbus-send` to `org.awesomewm.awful.Remote.Eval`, with an rlwrap REPL when stdin is a tty and a stdin-slurp mode when it is not. The server side (`lib/awful/remote.lua`) does `load(code)` then `pcall`, returning D-Bus type-tagged pairs: `"b"` for boolean, `"d"` for number, and `"s"` `tostring(v)` for everything else.

Worth taking as shape: the three CLI modes, returning the *list* of results rather than a single value, and treating a load error and a runtime error as distinguishable outcomes.

Worth rejecting: the transport, the `tostring` fallback, and that it is enabled unconditionally by `require("awful")` with no timeout, no depth limit, and no authentication beyond session-bus reachability. `docs/lua-api.md:96` requires lunette to have a switch that disables it.

awesome is GPL-2 and lunette GPL-3-only, so no code is taken (`docs/decisions.md:11`, `:13`).

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: `lunette.reload()`

**Verifies:** `lunette-v1.AC5.4`.

**Files:**
- Create: `crates/lunette/src/reload.rs`
- Modify: `crates/lunette/src/lua/mod.rs`

**Step 1: Run teardown first**

Call Phase 6 Task 4's registry before touching anything else. Hooks run in reverse registration order, and one raising does not prevent the rest — that is the registry's contract and this is its only caller in v1.

**Step 2: Clear the right namespaces**

`package.loaded` for **user and standard-library namespaces only**. `docs/lua-api.md:62` scopes it that way, and the reason is concrete: clearing `lovr.*` would make the next `require 'lovr.graphics'` re-run module initialisation against a live graphics module.

Enumerate what to clear by prefix rather than by exclusion list, so a module added later is covered by default and `lovr.*` is never at risk.

**Step 3: Reset user callbacks**

`main.lua` defines `lovr.draw`, `lovr.update`, and the `lovr.lun*` handlers (`docs/lua-api.md:18`). Re-running it redefines the ones it still defines — but a callback the user *deleted* from their config stays bound to the old function and keeps being called.

Clear the user-settable callbacks before the re-run. The specification does not say this; it follows from `main.lua` owning them, and omitting it produces a reload that silently keeps executing deleted code.

**Step 4: Re-run `main.lua`**

Through the same path Phase 1 established. A failure here does **not** fall into safe mode — safe mode is for load failure at startup (`docs/lua-api.md:76`). A reload that fails leaves the session running and reports the error, because the user has a working session in front of them and can fix the file and reload again.

**Step 5: Nothing native restarts**

LÖVR modules, the XR session, GPU objects, the compositor thread, and every client keep running. `docs/lua-api.md:62` calls it "effectively instant, with no visual disruption", and that is the whole point of soft reload existing alongside restart.

**Step 6: Test**

Cover: teardown hooks run before clearing; `lovr.*` is never cleared; user namespaces are; a deleted callback stops being called; a reload with a failing `main.lua` leaves the previous session running and reports; no client disconnects; timers and signal connections do not accumulate across ten reloads.

**Verification:** `cargo test -p lunette`

**Step 7: Commit**

```bash
git add crates/lunette/src/reload.rs crates/lunette/src/lua/mod.rs
git commit -m "feat: reload the lua state without disturbing clients"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Re-adopting state after a reload

**Verifies:** `lunette-v1.AC5.4`.

**Files:**
- Modify: `lua/mullion/persist.lua`, `lua/mullion/panel.lua`

**Step 1: Re-enumerate**

After a reload the Lua state knows nothing. The only mechanism for finding the windows that are still there is `lunette.windows()`, which reads the current snapshot.

`WindowId` is stable across a soft reload — the compositor thread is not restarted — and Phase 6 Task 1 documents that. Lua re-associates on it.

**Step 2: Read poses back from the property store**

Phase 6 Task 1's store survives the Lua state being discarded, which is why it exists. A panel the user grabbed and moved reads its pose back from the store rather than being replaced by whatever a rule would have chosen.

**Step 3: Rules are a separate source**

Re-running rules against surviving windows would undo every manual placement. Restore is a distinct source from apply-on-open, composed through Phase 6 Task 9's declared precedence.

A window that has stored state is restored; a window that has none is placed by rule. That is the same distinction awesome draws with its startup flag, and it is why the precedence must be declarable rather than implicit.

**Step 4: Test**

Headless, with a fake `lunette` API. Cover: a hand-placed panel returns to its stored pose after a reload; a window with no stored state is placed by rule; a window that closed during the reload is not resurrected; a window that opened during the reload is picked up.

**Step 5: Commit**

```bash
git add lua/mullion/
git commit -m "feat(mullion): re-adopt windows and poses after a reload"
```
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 3-4) -->
<!-- START_TASK_3 -->
### Task 3: The restart quiesce protocol

**Verifies:** `lunette-v1.AC5.5`.

**Files:**
- Create: `crates/lunette/src/restart.rs`
- Modify: `crates/lunette-compositor/src/protocol.rs`, `src/thread.rs`

The most exacting task in the phase. Getting the ordering wrong produces a `vkDestroyDevice` on a device with live images, which aborts or leaks.

**Step 1: Add the quiesce command**

A new `Command` variant that tells the compositor thread to release every GPU object it holds: each imported `VkImage`, each `VkDeviceMemory`, the import cache, and its copy of the `VkDevice`.

It acknowledges over the event channel when done. The main thread blocks on that acknowledgement. This is the one place in the design where the frame thread waits on the compositor thread, and it is justified: the alternative is destroying a device out from under live handles.

**Step 2: The compositor thread survives**

Only its GPU state dies. The Wayland display, the listening socket, every client connection, and the `wl_buffer` state all stay exactly as they are.

This is what makes AC5.5 possible at all, and it works because the compositor never speaks Vulkan to a client — it imports fds. `docs/architecture.md:58` records the rule that makes it safe: Rust holds no long-lived references into Lua, so nothing it owns is invalidated by the Lua state going away.

Retain the dmabufs themselves. Task 4 re-imports from them, and they are the reason clients do not need to redraw.

**Step 3: Run before `luax_close`**

Drive the quiesce from `lovr.restart`, or immediately before the step function returns `'restart'`. Both run while the device is still alive.

**Do not register it as a `luax_atexit` finalizer.** The chain is a linked list with no ordering guarantee relative to `lovrGraphicsDestroy`, and `graphics.c:891-894` already records LÖVR's own headset-versus-graphics ordering as "really hacky". Adding a third participant with a hard ordering requirement to an ordering nobody is confident in is how this breaks intermittently.

Comment the ordering requirement at the call site, naming `gpu_destroy` and the finalizer chain, because the constraint is invisible from the Rust side.

**Step 4: What LÖVR then destroys**

For reference, so a reader can check the quiesce covers it: `luax_close` (`api.c:514-539`) runs `lovrGraphicsDestroy` → `gpu_destroy()` → `vkDeviceWaitIdle`, `vkDestroyDevice`, `vkDestroyInstance` (`gpu_vk.c:3645`, `:3679`, `:3682`), and `lovrHeadsetDestroy` → `xrDestroySession` (`headset.c:1289`), `xrDestroyInstance` (`:3580`).

Phase 3's layer pool also dies here, and Phase 3 Task 4 already handles session loss by discarding its state and re-granting.

**Step 5: The cookie**

Whatever `lovr.restart` returns becomes the cookie, arriving in the new state as `arg.restart` (`main.c:40-42`). It is a single `Variant`, so nested tables survive; LÖVR objects are zeroed at `main.c:69`.

Use it for what Lua wants carried across. Do not use it for anything native — the compositor's state lives in Rust and never passes through Lua.

**Step 6: Test**

Against a fake compositor thread. Cover: quiesce releases every tracked GPU object; the main thread blocks until acknowledged; the dmabufs are retained; the Wayland socket and client connections are untouched; a quiesce with nothing imported completes immediately; a compositor thread that fails to acknowledge within a bound is reported rather than deadlocking the restart.

**Verification:** `cargo test -p lunette` and `cargo test -p lunette-compositor`

**Step 7: Commit**

```bash
git add crates/lunette/src/restart.rs crates/lunette-compositor/src/
git commit -m "feat: quiesce compositor gpu state before restart"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Restart recovery

**Verifies:** `lunette-v1.AC5.5`.

**Files:**
- Modify: `crates/lunette/src/restart.rs`, `src/boot.rs`

**Step 1: Republish the device**

`main.c:33` builds a fresh `luaL_newstate()` and boot proceeds as at startup: graphics initialises, a new `VkInstance` and `VkDevice` are created, and the XR session is recreated.

Send the new handles to the compositor thread, which has been idle since acknowledging the quiesce. Phase 2's startup ordering applies unchanged — clients cannot be served until the device exists — the difference being that here the clients are already connected and waiting.

**Step 2: Re-import**

Re-import every retained dmabuf against the new device, through Phase 2 Task 8's path. Rebuild the import cache.

Clients notice nothing. They never held a Vulkan handle, and their `wl_buffer` objects are unchanged. This is the property that makes AC5.5 achievable and is worth stating in a comment, because "the GPU device was destroyed and recreated but the clients are fine" is surprising on first reading.

**Step 3: Rebuild the layer pool**

Phase 3 Task 4 handles session loss: the pool discards everything, revokes every grant with `lovr.lunlayerrevoked`, and re-grants as it refills. Nothing extra is needed here beyond confirming the pool observes this restart as a session loss.

**Step 4: Failure**

If the new device cannot be created, or re-import fails for a buffer, the session cannot continue for that surface. Report it and let the client redraw into a fresh buffer rather than presenting stale or absent content. A single failed re-import must not take down the session.

**Step 5: Test**

Cover: after quiesce and republish, every retained dmabuf re-imports; the import cache is rebuilt; clients remain connected throughout; a failed re-import is reported without failing the restart; the layer pool re-grants from empty.

**Verification:** `cargo test -p lunette`

**Step 6: Commit**

```bash
git add crates/lunette/src/restart.rs crates/lunette/src/boot.rs
git commit -m "feat: re-import client buffers after restart"
```
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (tasks 5-8) -->
<!-- START_TASK_5 -->
### Task 5: The control thread and socket

**Verifies:** `lunette-v1.AC8.2`.

**Files:**
- Create: `crates/lunette/src/control/mod.rs`, `socket.rs`
- Modify: `docs/lua-api.md`, `docs/design-plans/2026-08-05-lunette-v1.md`

**Step 0: Correct the documented path**

`docs/lua-api.md:80` and the design plan (line 325) both give the socket as `$XDG_RUNTIME_DIR/lunette-0.sock`. Step 1 moves it into a 0700 directory, so it becomes `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`.

Update both, and record why in a sentence: the directory mode is what makes the 0600 requirement enforceable, because `fchmod` on a socket fd does nothing on Linux. Anyone reading the documented path and reproducing it without the directory would reintroduce the race.

**Step 1: A 0700 directory, then bind inside it**

`UnixListener::bind` creates the inode with `0777 & ~umask` and offers no pre-creation hook. The three obvious fixes are mostly wrong:

- **`fchmod` on the listener fd does nothing on Linux.** The fd refers to the socket object, not the filesystem inode; the call succeeds and changes nothing.
- **bind then `set_permissions`** leaves a window where the socket is world-accessible, and a connection accepted in that window stays valid.
- **`umask`** is process-global and not thread-safe.

So: create `$XDG_RUNTIME_DIR/lunette/`, set it 0700, and bind `lunette-0.sock` inside it. The directory mode closes the race entirely — no other uid can traverse in regardless of the socket's mode. Set 0600 on the socket as well, for defence in depth.

Comment why `fchmod` is not used. It is the obvious thing to reach for and it looks correct.

**Step 2: Validate the runtime directory**

Check `$XDG_RUNTIME_DIR`'s ownership and mode at startup rather than trusting it. The XDG specification mandates 0700 and user ownership; a specification is not an enforcement, and a wrong answer here silently undoes Step 1.

Per `CONTRIBUTING.md:110` a library never reads the environment. The binary reads the variable and passes the path in.

**Step 3: Handle a stale socket**

A crashed instance leaves the file behind. Unlink it only after confirming nothing is listening — attempt a connection first. Unlinking unconditionally lets a second instance silently steal a running instance's path, and the symptom is that `lunctl` talks to the wrong session.

**Step 4: Never a network address**

`docs/lua-api.md:99` and AC8.2 both require it. There is no configuration that makes this listen on a network address; the type is a Unix listener and nothing accepts a host or port.

**Step 5: A switch to disable it**

`docs/lua-api.md:96` requires one. Default it on — the whole point is in-headset iteration — but a user who wants no evaluation endpoint must be able to have none.

**Step 6: Bounded work**

The control thread accepts connections and reads chunks. It does not evaluate them: evaluation happens on the Lua thread between frames (Task 6). Use a bounded channel, so a client flooding chunks applies backpressure rather than growing a queue.

**Step 7: Test**

Cover: the directory is created 0700 and the socket 0600; binding twice reports rather than stealing; a stale socket with no listener is replaced; a stale socket with a live listener is not; the disable switch prevents creation entirely; a full channel applies backpressure.

Socket tests bind in a per-test temporary directory, which is the narrow exception Phase 1 Task 10 records — this is the listener itself under test, and it cannot be exercised over a socketpair.

**Verification:** `cargo test -p lunette`

**Step 8: Commit**

```bash
git add crates/lunette/src/control/
git commit -m "feat: add the lunctl control socket"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Chunk evaluation

**Verifies:** `lunette-v1.AC8.2`.

**Files:**
- Create: `crates/lunette/src/control/eval.rs`
- Modify: `docs/design-plans/2026-08-05-lunette-v1.md`, `docs/decisions.md`

**Step 1: Between frames, on the Lua thread**

Chunks evaluate on the main thread between frames, never concurrently with `lovr.update` or `lovr.draw`. That is what makes it safe for a chunk to touch the same state a callback touches, and `docs/lua-api.md:95` specifies it.

**Step 2: `jit.off`, then the count hook**

`debug.sethook(fn, "", N)` with a count hook is the mechanism, but under LuaJIT **JIT-compiled code does not call debug hooks** — a trace in a tight loop never returns to the interpreter and the hook never fires.

Apply `jit.off` to the loaded chunk so it runs interpreted and the hook fires reliably. The cost is irrelevant: a control-plane chunk is not a hot path. The alternative, building LuaJIT with `-DLUAJIT_ENABLE_CHECKHOOK`, would slow the entire session to bound one feature.

**Step 3: Restate AC8.2's first clause**

Even with `jit.off` the budget is advisory. An `error()` raised from a hook can be caught by a `pcall` inside the user's own chunk, and a loop inside a C function or a blocking FFI call is uninterruptible by any hook.

Decided on 2026-08-06: best-effort, documented honestly. A hard bound needs a watchdog outside Lua, and since the chunk holds the Lua thread the only thing a watchdog could do is abort the process — turning a bad `lunctl` command into a crash that takes every running client with it, which is worse than the hang it prevents.

Restate AC8.2's first clause in the design plan as best-effort, and record the reasoning in `docs/decisions.md` with the LuaJIT specifics, so the limitation is understood as a runtime property rather than an oversight.

**Step 4: Distinguish load from runtime errors**

A chunk that does not compile and a chunk that raises are different outcomes and a caller can act differently on each. awesome collapses both into one string; do not.

**Step 5: Return the list**

A chunk returning multiple values returns all of them, not just the first. This is one of the few things worth taking from awesome's shape.

**Step 6: Test**

Cover: a chunk returning multiple values returns all; a load error is distinguishable from a runtime error; a chunk exceeding the budget is abandoned and reported; a chunk that catches the abort with `pcall` is documented as escaping the budget and the test asserts the documented behaviour rather than an aspiration; evaluation never overlaps a frame callback.

**Verification:** `cargo test -p lunette`

**Step 7: Commit**

```bash
git add crates/lunette/src/control/eval.rs docs/
git commit -m "feat: evaluate lunctl chunks under a best-effort budget"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Serialisation

**Verifies:** `lunette-v1.AC8.1`.

**Files:**
- Create: `crates/lunette/src/control/serialise.rs`

**Step 1: A tagged value tree**

Each node carries its type: nil, boolean, number, string, table, handle, or error. Frame messages with a length prefix.

**Step 2: Handles as opaque ids**

`{tag = "handle", kind = "window", id = <n>}`, where the id is the Rust-side generational id already backing the handle (`docs/architecture.md:48`).

**Not `tostring(table)` addresses.** Those are reused after collection, so an id could silently come to refer to a different object — the kind of bug that appears only under memory pressure.

`docs/lua-api.md:97` names this as an improvement over awesome, which falls back to `tostring` for anything that is not a boolean or a number.

**Step 3: Error rather than drop**

Functions, coroutines, and userdata are unrepresentable. Table and function keys have no stable representation.

**Error on each, naming the path to the offending value.** `CONTRIBUTING.md` is explicit that silently dropping content you cannot represent is a correctness bug, not a convenience. A `tostring` fallback is exactly the failure `docs/lua-api.md:97` criticises.

**Step 4: Decide the awkward cases**

Each needs an answer, and each is a source of silent corruption if left implicit:

- **Cycles**: track a seen-set. Error, or emit a back-reference — pick one and document it.
- **Shared subtables**: a naive tree serialiser duplicates them. Say whether identity is preserved.
- **Mixed array and hash parts**: `{1, 2, x = 3}` has no JSON equivalent. The tagged representation should carry both.
- **`nil` holes**: they change `#t`. Do not rely on the length operator.
- **NaN, infinity, and integer-versus-float precision**: decide the wire representation.
- **`__index` and `__pairs`**: they can hide or fabricate fields. Decide whether to honour metamethods and say so.

**Step 5: Cap depth and node count**

LÖVR's own `luax_checkvariant` uses depth 128 with a cycle check (`api.c:561-562`), which is a reasonable precedent. A cap turns a pathological structure into a clean error instead of a stack overflow.

**Step 6: Test**

Cover each awkward case explicitly rather than trusting a generator: a nested table round-trips; a cycle produces the documented behaviour; a shared subtable preserves or does not preserve identity as documented; a function value errors naming its path; a handle round-trips to the same object; a dead handle's id serialises and deserialises to something inert; depth and node caps produce clean errors; mixed array and hash parts survive.

A round-trip property earns its place here — this is a public wire protocol, which is exactly the case `CONTRIBUTING.md:142` describes.

**Verification:** `cargo test -p lunette`

**Step 7: Commit**

```bash
git add crates/lunette/src/control/serialise.rs
git commit -m "feat: serialise lua values for lunctl with opaque handle ids"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: The `lunctl` binary

**Verifies:** `lunette-v1.AC8.1`.

**Files:**
- Create: `crates/lunctl/Cargo.toml`, `src/main.rs`
- Modify: `Cargo.toml` (workspace members)

**Step 1: Three modes**

A chunk as an argument, a chunk on stdin, and an interactive REPL when stdin is a terminal. This is awesome-client's shape and it is the right one.

**Step 2: Output**

Render the deserialised value tree readably. Handles show their kind and id, since that is all they are on this side of the socket.

Exit non-zero on a load error or a runtime error, so `lunctl` composes in a shell script. The end-to-end tests in Task 11 depend on this.

**Step 3: Errors**

Report a load error and a runtime error differently, matching Task 6's distinction. A connection failure — no socket, or the switch disabled it — is a third case and should say which.

**Step 4: Test**

The protocol is tested in Task 7; this binary is tested end to end in Task 11.

**Step 5: Commit**

```bash
git add crates/lunctl/ Cargo.toml Cargo.lock
git commit -m "feat: add the lunctl binary"
```
<!-- END_TASK_8 -->
<!-- END_SUBCOMPONENT_C -->

<!-- START_TASK_9 -->
### Task 9: Error handling

**Verifies:** `lunette-v1.AC8.3`.

**Files:**
- Modify: `crates/lunette/src/lua/mod.rs`
- Create: `crates/lunette/src/events.rs`

**Step 1: `xpcall` with a traceback**

Every user callback. The traceback matters — an error message without one is nearly useless for a callback invoked from native code.

`CONTRIBUTING.md:68` tells Lua authors to raise normally and not swallow errors to keep a frame alive. This is the machinery that makes that advice safe.

**Step 2: Push `lovr.lunerror`**

Build a `CustomEvent` and call `lovrEventPush`, as `l_event.c:162-179` does from Lua. `lovrEventPush` is thread-safe, so the compositor thread can push directly rather than marshalling through the main thread.

Two limits apply to every `lun*` event, not only this one:

- **Names cap at 31 characters plus a NUL** (`event.h:102-106`, `char name[32]`). Everything planned fits; the limit is recorded so a longer name is not invented later and truncated silently.
- **Only four payload arguments reach the handler** (`boot.lua:193`, `:198`). Payloads travel as a single table, per `docs/lua-api.md:42`.

`'quit'` and `'restart'` are intercepted before dispatch and are reserved.

**Step 3: The session continues**

An error in a callback does not end the frame or the session. Report it and carry on.

**Step 4: Rate limiting and the panel are mullion's**

Phase 6 Task 4 built the rate-limited handler and `docs/lua-api.md:74` says the handler is mullion code so it stays replaceable. This task provides the native side: the `xpcall` wrapping and the event.

Do not duplicate rate limiting natively. Two rate limiters with different keys produce confusing gaps.

**Step 5: Test**

Cover: an error in a callback is caught with a traceback and the session continues; `lovr.lunerror` is delivered with a table payload; an event name at the length limit round-trips and one over it is rejected at build time rather than truncated; a callback erroring every frame does not prevent later frames.

**Verification:** `cargo test -p lunette`

**Step 6: Commit**

```bash
git add crates/lunette/src/lua/mod.rs crates/lunette/src/events.rs
git commit -m "feat: catch callback errors and report them through lunerror"
```
<!-- END_TASK_9 -->

<!-- START_TASK_10 -->
### Task 10: Safe mode

**Verifies:** `lunette-v1.AC8.4`.

**Files:**
- Modify: `crates/lunette/src/boot.rs`

**Step 1: Wire the trigger**

When `main.lua` fails to load, run Phase 6 Task 12's embedded chunk instead.

This is the one failure path native owns (`docs/lua-api.md:76`). Everything else is Lua's, because `lovr.errhand` is overridable and the standard library must be replaceable.

**Step 2: Load failure only**

Safe mode is for a `main.lua` that fails to *load* — a syntax error, a missing file, an error raised at the top level. A runtime error in a callback of a config that loaded fine goes to Task 9, and a failed reload leaves the previous session running (Task 1).

Conflating these would replace a working session with safe mode over one bad frame.

**Step 3: Report why**

Show the load error inside safe mode. A user in a headset seeing a bare fallback with no explanation has to remove it to find out what happened, which is exactly the loop safe mode exists to avoid.

**Step 4: It cannot require mullion**

Phase 6 Task 12 establishes this and it is worth restating at the call site: mullion may be *why* loading failed, so safe mode uses only the `lunette` API.

**Step 5: Test**

Cover: a syntactically invalid `main.lua` produces safe mode; a missing `main.lua` produces safe mode; the load error is available to it; safe mode runs with the standard library entirely absent; a runtime error after a successful load does *not* produce safe mode.

**Verification:** `cargo test -p lunette`

**Step 6: Commit**

```bash
git add crates/lunette/src/boot.rs
git commit -m "feat: fall back to safe mode when main.lua fails to load"
```
<!-- END_TASK_10 -->

<!-- START_TASK_11 -->
### Task 11: End-to-end tests and gates

**Verifies:** All Phase 7 criteria.

**Files:**
- Create: `tests/e2e/lunctl.sh`

**Step 1: The end-to-end shell tests**

`docs/build-and-development.md:71` describes them: "a shell script that spawns a client, evaluates Lua to assert state, and tears down."

Drive `lunctl` to spawn a client, assert it appears in `lunette.windows()`, assert its properties, and tear down. Exit codes from Task 8 are what makes assertion possible.

Use a unique identifier per run rather than expecting pristine state, per `CONTRIBUTING.md:141`. Clean up the spawned processes — they are long-lived resources.

**Step 2: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 3: The human gates**

- A soft reload applies a layout change without disconnecting any client, and a hand-placed panel keeps its pose (AC5.4).
- `lunette.restart()` rebuilds the Lua state and the XR session while clients stay connected, with the expected visible hitch and brief blackness (AC5.5). Watch for a Vulkan validation error at teardown — that would mean the quiesce missed something.
- An error in a callback shows a panel and the session continues, and an error repeating every frame is rate-limited (AC8.3).
- A syntactically invalid `main.lua` produces safe mode with a laser, a panel, and a reload key, not a black headset (AC8.4).

**Step 4: Verify the socket mode by inspection**

`ls -ld` the directory and `ls -l` the socket: 0700 and 0600. `ss -lx` shows it listening on a path, never a network address.

**Step 5: Record the restart findings**

Append to `docs/milestone-0-findings.md`: whether the quiesce covered every GPU object, whether re-import succeeded for every retained dmabuf, whether any client noticed, and how long the restart took end to end.

**Step 6: Commit**

```bash
git add tests/e2e/ docs/milestone-0-findings.md
git commit -m "test: drive lunctl end to end"
```
<!-- END_TASK_11 -->

---

## Done when

- A soft reload applies a layout change without disconnecting any client, and hand-placed poses survive it.
- `lunette.restart()` rebuilds the Lua state and the XR session with clients still connected and no Vulkan validation errors at teardown.
- End-to-end shell tests drive `lunctl` to spawn a client, assert state, and tear down.
- An error in a callback shows a panel and the session continues, rate-limited on repeat.
- An invalid `main.lua` produces safe mode.
- The socket is 0600 inside a 0700 directory and never listens on a network address.
- All five check commands pass.

## Deliberately not in this phase

- A watchdog enforcing a hard chunk timeout. Considered and rejected: it could only abort the process, taking every connected client with it.
- Authentication on the control socket. Filesystem permissions are the boundary, which is why Task 5 spends its effort there.
- Restarting the compositor thread. It survives both reload and restart by design; only its GPU state is rebuilt.
- Per-panel output scale and pacing — Phase 8.
