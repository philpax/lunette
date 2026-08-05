# Architecture

## One process, three threads

lunette is a single Rust binary that statically links LÖVR. It owns `main()`.

| Thread | Owns | Talks to |
|---|---|---|
| Main | The LÖVR Lua state, the OpenXR session, all GPU submission, rendering | Compositor thread via channels; control socket via channel |
| Compositor | The Wayland display, smithay state, clients, surfaces, seats, child processes | Main thread via channels; imports images on LÖVR's `VkDevice` |
| Control | The `lunctl` Unix socket | Main thread; chunks execute on the Lua thread between frames |

Capture and PipeWire bring their own threads, owned by `wlx-capture`.

Rust hosts LÖVR rather than the reverse because a window manager has a lot of lifecycle that predates and outlives graphics: a Wayland socket to hold, child processes to reap, PipeWire and D-Bus connections, a control socket, and a session that should survive a GPU reinit. Running that inside a LÖVR project's `main.lua`, under LÖVR's CLI and `lovr.conf`, would put the tail in charge of the dog.

The cost is that "full access to LÖVR" becomes our responsibility. We boot the real LÖVR Lua environment with its real `boot.lua`, not a curated subset. If `lovr.physics` doesn't work in lunette, that's a bug.

## Why the compositor gets its own thread

WayVR ticks its compositor on the main thread once per frame (`inspiration/wayvr/wayvr/src/backend/wayvr/mod.rs:641`). That's simpler, it's proven, and it makes Lua's view of compositor state synchronous.

We don't do that, because an overlay's entire value proposition is not disturbing the application underneath. Anything slow in compositor dispatch — a client flooding requests, a D-Bus round trip, `posix_spawn`, a stalled `wl_display` write — lands directly in a 90 Hz frame budget. Moving it off the frame thread makes that class of hitch structurally impossible.

## The snapshot model

The consequence of that threading choice is the most user-visible decision in the system:

**Lua sees window state as a per-frame snapshot. Every mutation is a request.**

- `win.title` is a field on a handle, refreshed at frame start.
- `win:close()` returns nothing. You learn it worked when the window stops appearing.
- `win:resize(w, h)` is a configure request. The client may ignore it, clamp it, or take three frames.

This isn't a compromise forced by threading. Wayland is asynchronous, and awesome makes the same bargain against X11 — properties are cached, requests are async, reality arrives via events. Any API that pretends otherwise is lying, and would have to break later.

## Handles

A window handle is a **persistent Lua object with stable identity**, not a fresh table each frame. Native refreshes its fields at frame start.

```lua
function lovr.lunwindowopened(win)
  win.userdata = { spawnedAt = lovr.timer.getTime() }   -- yours to hang things on.
  print(win == lunette.windows()[1])                    -- identity works.
end
```

Handles are needed for tags, rules, and signals to be expressible at all — every one of them needs to say "this window, the one I saw last frame".

### Dead handles are inert

When a window closes, Lua may still hold its handle. Reads return the last known values plus `win.dead == true`. Every method becomes a no-op returning `false`.

It's ugly. The alternative is worse: "window vanished between frames" is normal in a compositor, not exceptional, and raising an error for it means a stray race takes down your desktop.

## Ownership rules

**Rust never holds a long-lived reference into Lua.** No registry refs to callbacks, no native objects with hidden Lua back-pointers.

This isn't fastidiousness. It's what makes soft reload work ([The Lua API](lua-api.md#reload)): if all authoritative state lives in Rust, we can discard the user's Lua world and republish every handle into a fresh one without the compositor noticing. It also removes a whole category of GC-interaction bugs at the Rust/Lua boundary.

**The lunette API is main-Lua-state only.** `lovr.thread` and `lovr.task` create additional Lua states; lunette's API isn't available in them. Window management from a worker thread isn't something anyone needs, and pretending otherwise costs real synchronisation. If a use case appears later, the likely shape is read-only snapshot access in worker states — deliberately left open, not designed for.

## GPU ownership

LÖVR creates the `VkInstance`, `VkPhysicalDevice`, `VkDevice`, and queues. The compositor thread uses that device for one thing: **creating images from imported dmabufs**. It never submits work to a queue.

That restriction is load-bearing. Copies into composition-layer swapchains are issued inside LÖVR's own command stream on the main thread, so ordering against LÖVR's rendering is LÖVR's internal business, and we never race its queue from another thread. See [Rendering](rendering.md).

## Layering discipline

```
lunette            binary; owns main(), Lua injection, frame orchestration
lunette-compositor smithay; no LÖVR dependency, no GPU dependency beyond image creation
lunette-capture    wlx-capture + HidProvider wrappers
lunette-lovr       cmake build, FFI surface, the patch set
```

`lunette-compositor` must not depend on `lunette-lovr`. That keeps logic-headless testing reachable ([Build and development](build-and-development.md#testing)) and stops the graphics module becoming a hard dependency of window management.

## What survives what

| Event | Wayland clients | GPU/XR session | Lua state |
|---|---|---|---|
| Soft reload (`lunette.reload()`) | survive | survives | discarded |
| Hard restart (`lunette.restart()`) | survive | torn down and rebuilt | discarded |
| lunette crash | killed (process group) | gone | gone |

Clients survive both reload paths because they're owned by Rust, outside the Lua state, holding a socket that doesn't close. That property is what makes iterating on a compositor bearable.
