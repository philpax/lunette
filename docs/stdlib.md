# Standard library

`mullion` is Lua, installed to `$PREFIX/share/lunette/lua/`, readable and forkable. It's written against the same public API a downstream user has — if it ever needs something private from `lunette`, that's a bug in the API, not a licence to add a back door.

**Nothing here is settled.** Much of it will be in flux, and it should be. What follows describes the intended tiers and the minimum viable version of each, not a committed API surface. Concrete signatures land once we've used the thing.

## Tier 1 — surfaces and panels

The irreducible core. A panel binds a pixel source to a pose and a size in metres, decides between a composition layer and in-scene geometry, converts ray hits to pixel coordinates, and draws chrome.

**Minimum viable:** create a panel from a window or a monitor, place it with a `mat4`, draw it in-scene, raycast a quad, feed the sink. Enough for a config to put a terminal on a wall and click it.

Design constraint: a panel is an abstraction built *over* the primitives, not a privileged object. You can use windows and sinks without ever creating one.

## Tier 2 — interaction

Grab-to-move, grab-to-resize, laser pointers with per-hand cursors, hover and focus feedback, pointer modes (WayVR's laser-colour-selects-click-type idea), scroll, and a virtual keyboard.

Very tuning-heavy. Feel is most of the work here.

**Minimum viable:** one laser per hand, hover highlight, trigger-to-click, grab-to-move, and a keyboard that can type into the focused sink.

## Tier 3 — layout and policy

The awesome part. Tags and workspaces, layout algorithms (an arc around you, a grid on a wall, a stack, follow-head-with-lag), rules ("Firefox spawns on the left wall, 2m wide"), signals, and persistence of your arrangement between sessions.

Layout in 3D has no useful ancestor — awesome's algorithms are 2D and GPLv2, so we reimplement from scratch anyway. The interesting question is what "tiling" even means when the walls are wherever you decided they are.

**Minimum viable:** one layout function that arranges the current tag's panels in an arc at a comfortable radius, a rules table matched on `appId`, and layout save/restore to `lovr.filesystem`'s save directory.

## Tier 4 — furniture

A dashboard and launcher, notifications (`org.freedesktop.Notifications`), a watch or wrist menu, settings UI, a taskbar, IME integration.

This is where most of WayVR's code lives, and it's the most opinionated part of any of this.

**It ships as the default `main.lua` and example modules, not as library code.** Tiers 1–3 are things every user needs and would write identically; tier 4 is *your desktop*, and it should be readable Lua sitting in your config that you fork without ceremony.

**Minimum viable:** the default config spawns a terminal, shows it on a panel, and gives you a laser and a reload key. That's it.

## 2D widgets

Deferred. Titlebars and menus need *something*, but the ambition is deliberately low: a thin immediate-mode helper over LÖVR's `Pass`, not a widget toolkit with a layout engine.

Anything genuinely ambitious should be a real Wayland client we spawn, because then it gets the entire application ecosystem, real text rendering, and accessibility for free. A GTK settings app inside lunette beats a hand-rolled widget tree.

It may end up as a recommended-but-separate library rather than part of `mullion`, which is the honest framing: you're free to bring your own.

## What lives here versus in Rust

The recurring test, applied throughout the design:

| Concern | Where | Why |
|---|---|---|
| Layer priority ranking | Lua | Focus and gaze are application knowledge |
| Layer pool and recycling | Rust | Scarce, expensive, needs one owner |
| Raycasting | Lua | It's geometry, and geometry is the user's |
| Hit-testing within a surface | Rust | It's protocol |
| Key repeat | Lua | Timing policy |
| Keymap generation for `typeText` | Rust | Impossible from Lua |
| Frame rate per panel | Lua | Depends on where you're looking |
| Frame callback delivery | Rust | It's protocol |
| Clipboard mirroring policy | Lua | Someone may want isolation |
| Clipboard format negotiation | Rust | fds and MIME lists shouldn't enter Lua |
| Restart-on-crash for a spawned app | Lua | It's a preference |
| Reaping children | Rust | It's the kernel |
