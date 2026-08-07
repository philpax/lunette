# Standard library

`mullion` is Lua, installed to `$PREFIX/share/lunette/lua/`, readable and forkable. It is written against the same public API available to a downstream user. If it ever needs something private from `lunette`, that is a bug in the API, not a licence to add a back door.

Nothing here is settled. Much of it will be in flux, and it should be. What follows describes the intended tiers and the minimum viable version of each, not a committed API surface. Concrete signatures land once the thing has been used.

## How it is reached

The tree lives at `lua/mullion/` in the source and at `$PREFIX/share/lunette/lua/mullion/` once installed. The binary mounts the directory above it into LÖVR's virtual filesystem before `main.lua` runs, so `require 'mullion'` resolves `mullion/init.lua` and a configuration's first line may be that require. [Build and development](build-and-development.md#where-things-live-at-runtime) gives the search order, and [Decisions](decisions.md#recorded-decisions) records how the mount is installed and why it is read-only.

`mullion` itself is the root module and re-exports nothing. Each submodule is required by its own path — `require 'mullion.signal'`, `require 'mullion.layout.arc'` — because the tiers are independent and a configuration that wants one should not load the rest to get it. `mullion.layout.arc` and `mullion.tag.current` are the two names [The Lua API](lua-api.md) already attests.

The mount is read-only. A configuration that could overwrite the standard library it is running on top of could make a session unbootable in a way a reload cannot repair, since the reload would read the overwritten copy.

## What the tree holds

| Module | What it is |
|---|---|
| `mullion` | The root. It re-exports nothing and holds no state. |
| `mullion.signal` | `connect`, `weakConnect`, `disconnect`, `emit`, and `setProperty`, which announces `property::<key>`. |
| `mullion.teardown` | The hook registry a soft reload runs. Hooks are keyed by name and run in reverse registration order. |
| `mullion.error` | The `lovr.errhand` replacement [The Lua API](lua-api.md#errors) puts here, and the rate limiter it reports through. |
| `mullion.panel` | Tier 1. A source bound to a pose and a metre size, on a composition layer or an in-scene quad, with `rayQuadHit` for turning a ray into a pixel coordinate. The quad path draws with premultiplied blending, and through `panel.opaqueShader` for a source whose buffer has no alpha channel ([Rendering](rendering.md#alpha)). |
| `mullion.panel.raycast` | Where a ray meets a quad, in the quad's own pixels. Pure, and separate because a panel's realisation and a matrix inversion have nothing in common. `mullion.panel` re-exports `hit` as `rayQuadHit`. |
| `mullion.pose` | A `mat4` as a string, and back. The property store refuses a table and a file on disk holds text, so both want the same sixteen numbers. |
| `mullion.interaction` | Tier 2. A pointer over a set of panels: what it hovers, what it clicks, what it scrolls, and what it has grabbed. It reads no device and draws nothing. |
| `mullion.laser` | Tier 2. One per hand. It reads a pointer device, drives an interaction pointer with what it read, owns that hand's seat, and draws the beam. |
| `mullion.keycodes` | Where the keys are, in evdev keycodes, and which of them are modifiers. A description of a physical keyboard, with no layout in it. |
| `mullion.keyboard` | Tier 2. A virtual keyboard whose legends and keycodes come from a seat's own keymap rather than from a table of its own. |
| `mullion.tag` | Tier 3. Named groups of panels. A panel belongs to a set of tags and selection is multi, so `mullion.tag.current` answers tags rather than one tag. |
| `mullion.layout.arc` | Tier 3. Panels on a curve around the user, facing inwards. Callable, because [The Lua API](lua-api.md) attests it as a call. |
| `mullion.rules` | Tier 3. What a window should look like, decided before anything draws it. Several sources compose with a declared precedence, and the `appId` table is one of them. |
| `mullion.persist` | Tier 3. Arrangements that outlive the process. It captures panels, writes them to the save directory, and restores them as one of `mullion.rules`'s sources. |
| `mullion.persist.format` | The arrangement file's text and its versions. Pure, and separate because the version matrix is worth reasoning about without a filesystem in the way. |
| `mullion.adopt` | Tier 3. The windows a soft reload found already open. `adopt.windows` re-enumerates them, and `adopt.install` registers the native property store as the highest of `mullion.rules`'s sources, so a hand-placed panel comes back where the user left it rather than where a rule would have chosen. |

`mullion.interaction` and `mullion.laser` are one tier split in two because one of them can be tested and the other cannot. Everything that decides — which panel a ray hits, where a grab puts a panel, what a thumbstick deflection is worth in surface pixels — is in `mullion.interaction`, which is handed its input and reaches for no device. `mullion.laser` is the shell around it: `lovr.headset`, `lunette.newSeat`, and `Pass`.

Two of these are here rather than with the reload mechanism that calls them, and both for the same reason: every module registers a teardown hook, so the registry has to exist before the first module does, and the error handler is stated to be `mullion` code.

`lua/spec/` mirrors the tree and holds the specs. It is not installed: it covers the standard library and is not part of it. The specs run inside the binary, through `cargo test`, because the tree they are required through is LÖVR's virtual filesystem rather than the process's.

Three of them are about the suite rather than about a module. `spec/mullion/coverage_spec.lua` reads the module tree from the mount and fails when a module has neither a spec nor a recorded exemption, so an absence is deliberate. `spec/mullion/reload_spec.lua` requires every module twice against one registry and fails when a teardown hook or a global accumulates, which is what makes the rule above checkable rather than aspirational. `spec/runner_spec.lua` covers discovery, which is the one failure nothing else can catch: a discovery that skipped a directory would report the cases it found as passing and say nothing about the ones it never loaded.

## Tier 1 — surfaces and panels

The irreducible core. A panel binds a pixel source to a pose and a size in metres, decides between a composition layer and in-scene geometry, converts ray hits to pixel coordinates, and draws chrome.

Minimum viable: create a panel from a window or a monitor, place it with a `mat4`, draw it in-scene, raycast a quad, feed the sink. Enough for a config to put a terminal on a wall and click it.

Design constraint: a panel is an abstraction built over the primitives, not a privileged object. Windows and sinks can be used without ever creating one.

A panel reads `claim.granted` each frame rather than handling `lovr.lunlayergranted`. Grants and revocations land on frame boundaries and never mid-frame, so the two agree, and polling is one code path where handling the callbacks would be two. It also leaves the callback free: the `lovr.lun*` namespace belongs to the configuration, and a library that took one would be taking it.

A panel over a monitor never claims a layer. `lunette.claimLayer` takes a window and nothing else, so a mirrored screen has no way to ask for one and always draws as an in-scene quad. That is a gap in the native API rather than a decision the standard library made, and closing it is a change to `claimLayer`.

## Tier 2 — interaction

Grab-to-move, grab-to-resize, laser pointers with per-hand cursors, hover and focus feedback, pointer modes (WayVR's laser-colour-selects-click-type idea), scroll, and a virtual keyboard.

This tier is tuning-heavy. Feel accounts for most of the work.

Minimum viable: one laser per hand, hover highlight, trigger-to-click, grab-to-move, and a keyboard that can type into the focused sink.

Grab-to-resize is deferred rather than dropped. It is in the description above and not in the minimum viable line, and it shares every constant grab-to-move has: the dead zone that decides when a hand movement is deliberate, the reach, and the haptics. Tuning both at once means tuning neither, so resize lands once move has been used in a headset.

Hover and focus stay separate here for the reason [Input](input.md#seats) gives for keeping them separate in the compositor. A laser hovering a panel sends `sink:pointer` and takes `sink:leave` off whatever it left; only a click calls `seat:setFocus`. Inferring focus from pointer motion in Lua would be the heuristic the native layer deliberately does not have, one language further out.

## Tier 3 — layout and policy

The awesome-derived part. Tags and workspaces, layout algorithms (an arc around the user, a grid on a wall, a stack, follow-head-with-lag), rules ("Firefox spawns on the left wall, 2m wide"), signals, and persistence of the arrangement between sessions.

Layout in 3D has no useful ancestor. awesome's algorithms are two-dimensional and GPLv2, so this tier is reimplemented from scratch regardless. The open question is what "tiling" means when the walls are wherever the user decided they are.

Minimum viable: one layout function that arranges the current tag's panels in an arc at a comfortable radius, a rules table matched on `appId`, and layout save/restore to `lovr.filesystem`'s save directory.

Rules and restore are separate sources composed with a declared precedence, rather than one list. After a restart a window that was hand-placed should come back where it was, and a window opening fresh should be placed by rule; as one list, whichever the configuration happened to write second wins, and which of the two cases is wrong depends on that ordering. `mullion.persist` registers above the rules table by default, and a configuration that wants its rules to win says so with a number.

A soft reload wants the same composition against a shorter-lived store. `mullion.adopt` registers the native property store above both, because the store holds what the user did in this session and the file holds what they did in the last one. It also carries the re-enumeration: a reload discards the Lua state, `lovr.lunwindowopened` was delivered to the state that has gone, and `adopt.windows` is how the new one hears about the windows that are still open. A configuration that only ever placed windows from that callback comes back from a reload showing nothing at all.

The arrangement is written to `lovr.filesystem.getSaveDirectory()`, which derives from the identity rather than from the source — so it is not the configuration directory and is asked for rather than assumed. The file carries no `.lua` extension, so that a session cannot write something the require path would resolve as a module. A file written by a later version is left alone rather than parsed and rewritten, because rewriting it would drop the fields this version cannot represent. Two things enforce that. A load from a later version carries no arrangement, so there is nothing to hand the save; and the module remembers that the load was declined, so a save built freshly out of live panels is refused too. The second is what the first cannot cover: capturing panels constructs an arrangement that knows nothing about what was read, and a session that quits normally saves on the way out. A caller that has decided to overwrite it anyway says so in words. The refusal is forgotten once the module knows what is on disk again: a load that could be used clears it, and so does a write, including the forced one that overwrote the file the refusal was about.

## Tier 4 — furniture

A dashboard and launcher, notifications (`org.freedesktop.Notifications`), a watch or wrist menu, settings UI, a taskbar, IME integration.

Most of WayVR's code lives at this tier, and it is the most opinionated part of the design.

It ships as the default `main.lua` and example modules, not as library code. Tiers 1 through 3 are things every user needs and would write identically; tier 4 is the user's desktop, and it should be readable Lua sitting in the user's config, forked without ceremony.

Minimum viable: the default config spawns a terminal, shows it on a panel, and provides a laser and a reload key. Nothing more.

`etc/xdg/lunette/main.lua` is that config, and it is the source of truth for what ships. It declares one tag, attaches a laser to each hand, spawns the first terminal emulator it finds, places each window through `mullion.rules` and arranges the ones no source gave a pose to on an arc, and binds a reload key on the desktop window. It carries two things past the line above, both because an acceptance criterion is about them: a rules table matched on `appId`, and a saved arrangement installed as a second source and written back when a panel is dropped or the session quits. It installs `mullion.adopt` as a third source and adopts the windows already open in `lovr.load`, which is what makes the reload key keep a hand-arranged workspace rather than rearranging it.

Safe mode deliberately resembles it and shares no code with it. It is compiled into the binary and requires `lunette` alone, because a broken `mullion` is one of the reasons the user's configuration may have failed; [The Lua API](lua-api.md#errors) and [Decisions](decisions.md#recorded-decisions) state the rest.

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
