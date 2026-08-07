# Standard library

`mullion` is Lua, installed to `$PREFIX/share/lunette/lua/`, readable and forkable. It is written against the same public API available to a downstream user. If it ever needs something private from `lunette`, that is a bug in the API, not a licence to add a back door.

Nothing here is settled. Much of it will be in flux, and it should be. What follows describes the intended tiers and the minimum viable version of each, not a committed API surface. Concrete signatures land once the thing has been used.

## How it is reached

The tree lives at `lua/mullion/` in the source and at `$PREFIX/share/lunette/lua/mullion/` once installed. The binary mounts the directory above it into LÖVR's virtual filesystem before `main.lua` runs, so `require 'mullion'` resolves `mullion/init.lua` and a configuration's first line may be that require. [Build and development](build-and-development.md#where-things-live-at-runtime) gives the search order, and [Decisions](decisions.md#recorded-decisions) records how the mount is installed and why it is read-only.

`mullion` itself is the root module and re-exports nothing. Each submodule is required by its own path — `require 'mullion.signal'`, `require 'mullion.layout.arc'` — because the tiers are independent and a configuration that wants one should not load the rest to get it. `mullion.layout.arc` and `mullion.tag.current` are the two names [The Lua API](lua-api.md) already attests.

The mount is read-only. A configuration that could overwrite the standard library it is running on top of could make a session unbootable in a way a reload cannot repair, since the reload would read the overwritten copy.

## Tier 1 — surfaces and panels

The irreducible core. A panel binds a pixel source to a pose and a size in metres, decides between a composition layer and in-scene geometry, converts ray hits to pixel coordinates, and draws chrome.

Minimum viable: create a panel from a window or a monitor, place it with a `mat4`, draw it in-scene, raycast a quad, feed the sink. Enough for a config to put a terminal on a wall and click it.

Design constraint: a panel is an abstraction built over the primitives, not a privileged object. Windows and sinks can be used without ever creating one.

## Tier 2 — interaction

Grab-to-move, grab-to-resize, laser pointers with per-hand cursors, hover and focus feedback, pointer modes (WayVR's laser-colour-selects-click-type idea), scroll, and a virtual keyboard.

This tier is tuning-heavy. Feel accounts for most of the work.

Minimum viable: one laser per hand, hover highlight, trigger-to-click, grab-to-move, and a keyboard that can type into the focused sink.

## Tier 3 — layout and policy

The awesome-derived part. Tags and workspaces, layout algorithms (an arc around the user, a grid on a wall, a stack, follow-head-with-lag), rules ("Firefox spawns on the left wall, 2m wide"), signals, and persistence of the arrangement between sessions.

Layout in 3D has no useful ancestor. awesome's algorithms are two-dimensional and GPLv2, so this tier is reimplemented from scratch regardless. The open question is what "tiling" means when the walls are wherever the user decided they are.

Minimum viable: one layout function that arranges the current tag's panels in an arc at a comfortable radius, a rules table matched on `appId`, and layout save/restore to `lovr.filesystem`'s save directory.

## Tier 4 — furniture

A dashboard and launcher, notifications (`org.freedesktop.Notifications`), a watch or wrist menu, settings UI, a taskbar, IME integration.

Most of WayVR's code lives at this tier, and it is the most opinionated part of the design.

It ships as the default `main.lua` and example modules, not as library code. Tiers 1 through 3 are things every user needs and would write identically; tier 4 is the user's desktop, and it should be readable Lua sitting in the user's config, forked without ceremony.

Minimum viable: the default config spawns a terminal, shows it on a panel, and provides a laser and a reload key. Nothing more.

## 2D widgets

Deferred. Titlebars and menus need some form of widget support, but the ambition is deliberately low: a thin immediate-mode helper over LÖVR's `Pass`, not a widget toolkit with a layout engine.

Anything more ambitious should be a real Wayland client, spawned rather than built, because that gets the entire application ecosystem, real text rendering, and accessibility for free. A GTK settings app running inside lunette is preferable to a hand-rolled widget tree.

It may end up as a recommended-but-separate library rather than part of `mullion`. The user is free to bring their own.

## What lives here versus in Rust

The recurring test, applied throughout the design:

| Concern | Where | Why |
|---|---|---|
| Layer priority ranking | Lua | Focus and gaze are application knowledge |
| Layer pool and recycling | Rust | Scarce, expensive, needs one owner |
| Raycasting | Lua | It is geometry, and geometry belongs to the user |
| Hit-testing within a surface | Rust | It is protocol |
| Key repeat | Lua | Timing policy |
| Keymap generation for `typeText` | Rust | Impossible from Lua |
| Frame rate per panel | Lua | Depends on where the user is looking |
| Frame callback delivery | Rust | It is protocol |
| Clipboard mirroring policy | Lua | Some users want isolation |
| Clipboard format negotiation | Rust | fds and MIME lists should not enter Lua |
| Restart-on-crash for a spawned app | Lua | It is a preference |
| Reaping children | Rust | It is the kernel |
