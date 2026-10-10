# The Lua API

`require '@lunette'` is native mechanism: windows, monitors, sinks, seats, outputs, processes, layer claims, clipboard bridging, capture, events, and the plugin runtime. `require '@lunette-plugin'` is the plugin facade, written in Lua. Policy lives in the Lua roots `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop`, which use only public APIs, and `lunette` remains usable without them. [Module roots](build-and-development.md#module-roots) lists the aliases.

The generated `lua/lunette/init.luau` is the source of truth for the native API's members, fields, and argument shapes, and its comments describe each one. Each module under `lua/lunette-contracts/` is the source of truth for its contract's types, methods, and version, and each provider's `config.luau` or descriptor for its options and defaults. This document states the guarantees those files do not make plain. [The native API](../guide/native-api.md) and [Writing plugins](../guide/writing-plugins.md) are the user guides.

## Plugin authoring

[Architecture](architecture.md#plugin-runtime) specifies the plugin runtime: contract matching, publication, reservations, retry, quarantine, and epochs. This section specifies the facade over it.

`plugin.capability<<Service>> { name, version }` declares a contract and binds its native token in one step; the capability displays as `name@version`. A Lua state cannot declare the same name and version twice in one epoch. The facade does not export the native `contract` function. `lunette check` reports a capability whose service type is `unknown`, which is what omitting `<<Service>>` produces.

`plugin.provider` and `plugin.consumer` are the definition constructors. A definition's `requires` lists the capabilities it uses, and the facade keys each one by its contract for the native graph, so a duplicate or a value that is not a capability raises. `Publisher:provide` is valid only while the initializer runs; it stages a provision that the runtime publishes with the rest of the instance's provisions when the initializer returns. The runtime does not check service shapes or configuration values against Luau types. Plugin callbacks are synchronous. The facade rejects an unknown field or a wrongly typed value in a definition or capability spec.

The native plugin handles (token, definition, runtime, instance, context, and effect) are nominal types, so a table does not satisfy a parameter that takes one. A contract token belongs to its epoch, and source reload retires the epoch.

### Services

A consumer receives each provision through a frozen view shared by every consumer of that provider generation. Once the provider has begun unloading, reading, iterating, or calling through the view raises an error naming the contract, including through a reference kept past the consumer's own activation. Assigning a field always raises. A method receives the view as `self`, so a provider keeps mutable state in its own locals. The view checks a method when it is read, so a function read while the provider was live stays callable, and objects a method returned carry their own `dead` state. `pairs` and `#` see an empty table.

### Confinement

A plugin changes state outside itself only through its context. Every resource, subscription, and child an initializer creates goes through `Context:effect`, `Context:on`, `Context:child`, or an owner-scoped provider method, so unloading the instance reverts it. `Context:child(definition, config?)` takes an optional configuration and returns nothing. A direct `lunette.on*` call is untracked: it survives instance reload and the next activation duplicates it.

Effects are flat. An effect created during another effect's acquisition registers first, as a sibling, and inverses run in reverse registration order, so the outer inverse runs before the inner one. An outer inverse that must release the inner resource first disposes it itself. If the activation is cancelled during an acquisition, the inverse runs at once and the call raises. Disposing an effect whose activation has ended does nothing. A handler registered through `Context:on` is not called after the activation ends.

An owner-scoped provider method registers its resource on the caller's owner through one of three context methods. `Context:acquire(owner, acquire)` is the usual form. `Context:resource(owner, acquire)` is the same for an `acquire` that returns a value with its inverse, and returns the value with the effect. `Context:acquireDeferred(owner, acquire)` registers without draining queued lifecycle work before it returns, so that work waits for the next drain boundary; the theme provider's `select` uses it so that no queued activation runs between registering a selection and publishing it. Each accepts the provider's own context or a live dependent bound to the provider's current generation, and raises for any other owner before acquiring. `Context:checkOwner(owner)` raises for an owner that is not a live dependent, and `Context:owns(owner)` answers the same test as a boolean; a provider calls one of them before validating a call whose resource it registers later. An `Owner` exposes nothing callable, so a provider cannot register on an owner except through these methods. An inverse that raises during the owner's unload quarantines the owner, and the provider keeps serving others. A provider that needs one of its own dependencies for that work calls it with its own context as owner, inside the effect it registers for the caller, so the caller need not depend on the provider's dependencies. Only contexts the facade created are accepted as owners.

A change an owner makes to shared state, such as a panel's visibility or a tag's selection, is an override held by that owner, and the most recent live override decides. A name registered with a broker, a key chord, a rules source name, and a laser hand each have one holder, and registering a taken one raises.

An instance reserves the contracts it provides, so several implementations of one contract compose through a broker, as section 6.2 of the Cordis paper describes: one plugin provides the contract, and implementations register with it through an owner-scoped method. Layouts, themes, menu actions, bindings, rule sources, and surface offers are brokers.

### Instances

A request on an instance (`enable`, `disable`, `dispose`) takes effect immediately and raises at the call when the graph rejects it. `requestReload` accepts a replacement configuration without draining, and `Runtime:drain()` applies it. An instance's diagnostic is read from `Runtime:snapshot()`. Instance and owner identities are exact decimal strings.

### Provider modules

A module made by `plugin.provider` or `plugin.consumer` exposes `definition`, built from the defaults, and `define`, which binds other defaults and an optional `name`. A module's descriptor validates defaults at construction, bound settings at `define`, and configuration at activation, and each activation resolves its configuration afresh. Declared objects merge recursively; arrays, maps, unions, and atomic values replace. [Configuration schemas](../guide/configuration-schema.md) specifies descriptors.

Variation inside a provider is a hook: an option whose value is a function that receives its arguments followed by the default implementation, `hook(args..., base)`. A hook runs on the stack of whatever reached the provider, so its errors are reported there.

### Composition

A composition is a list of entries, `{ id, definition, config }`, where `definition` is a plugin definition or a factory of one. `plugin.compose(entries, patches)` returns the entries with the patches applied, validated, and frozen, and defines and enables nothing. `lua/lunette-plugin/compose.luau` is the source of truth for the patch rules. A patch that names an unknown or duplicate id, changes nothing, or both disables and changes an entry raises, because a patch that matches nothing does not do what it says.

`@lunette-plugin/management.start` is the one start path. It preflights every configuration through its definition's `resolve` before creating the runtime, so a configuration error aborts startup before any entry activates, while initializer failures stay local to their instances. The entry id `composition` is reserved. [Session composition and inspection](stdlib.md#session-composition-and-inspection) states entry management and recovery.

## Contracts

Every registration that takes an owner returns an effect and ends when the effect is disposed or the owner unloads. An owner-scoped override, such as a hidden panel or a selected tag, returns an effect the same way. A change notification is `on<Event>(owner, { run })`, where `run` receives the change's payload, and returns an effect. A listener or callback a provider invokes for another plugin runs under its own protected call and is reported through `lunette.reportError` without stopping the others. A call with a field the contract does not name raises at the call. Every broker that holds owner-scoped registrations implements `inspect()`, which returns registration metadata as data and invokes no plugin callback, and the plugin manager reads each one.

### Frame dispatch

`lunette/frame` delivers LÖVR's callbacks to plugins, and `lunette/surfaces` lists the surfaces a pointer can pick. Update handlers run in the phases `input`, `scene`, `pointing`, and `overlay`, and draw handlers in those and then `feedback`. `input` reads devices before the scene moves, `scene` updates and draws panels, `pointing` picks against this frame's surface poses, `overlay` draws UI over the scene, and `feedback` draws pointer beams after everything else. Within a phase, handlers run by ascending `order`, then in registration order. Key and text handlers run `binding` before `delivery`, and a handler that returns `true` consumes the event. Quit handlers cannot veto the quit.

Every handler and every surface offer's `list` runs under its own protected call. A raising key or text handler consumes nothing, and an offer that raises or returns something other than a table contributes no surfaces. [Input](input.md#physical-input-batches) specifies input batches and text blocking.

`frame.install { start, stop }` assigns the LÖVR callbacks once. `lovr.load` calls `start`; the other callbacks reach whichever frame activation is loaded and do nothing while none is. `lovr.quit` runs the quit handlers, then `stop` under a protected call, and returns `false`.

### Joined frame attachments

A surface may implement the optional `attachFrame(owner, style)` from `@lunette-contracts/vocabulary`, which passes resolved header style to the target. It is not a general transform or layout relationship. Attach and update validate and freeze the whole style before changing anything. A target permits one live attachment, and a second raises. Disposal is idempotent, and updating a disposed attachment or one whose target is dead raises.

The target computes `isJoined()` on each call: a panel joins while it is live, visible, flat, and drawn in the scene rather than on a granted layer, and a UI panel while it is live and visible. An ineligible attachment stays dormant and can join again. A joined target draws one outline in the header's border style around body and header, even when panel `chrome` is false; the titlebar draws its own face, text, and actions. [Joined flat frames](rendering.md#joined-flat-frames) defines the geometry. The shared titlebar holds one attachment per supporting target and disposes it when the heading hides, the titlebar is destroyed, or the owner unloads. The UI provider synchronizes retained titlebars in the `scene` phase at order 1000, after source and decoration updates and before picking.

### Keyboard

A keyboard is owned, placed, offered, and drawn by its owner, because a service-wide draw would show keyboards the drawing owner does not offer. A keyboard is pressed through its surface, and each keyboard delivers through a virtual `lunette/focus` source ([Input](input.md#virtual-activations-and-committed-text)). Rows, layers, and style are the provider's configuration. Visibility changes reach `onVisibilityChanged` after the state changes, and an unchanged visibility reports nothing.

A theme change refreshes each keyboard before its next input or draw. Key legends do not write depth. Each key hook and the whole draw restore pass state and transforms, including on error. The built-in provider validates rows by option path.

The keyboard display (`lunette/keyboard-display`, provided by the `desktop/keyboard` entry from `@lunette-plugins/keyboard-display`) owns the visibility of the one session keyboard. A focused local target that wants a keyboard shows it, and ending that editing hides it; a manual show survives the end of editing. An explicit hide, the titlebar close, or the board's hide action blurs only the matching local target. [Input](input.md#keyboard-routing) states the routing these rules follow.

### Pointers and drops

[Input](input.md#surface-pointer-input) specifies pointer capture, cancellation, and the event kinds. A pointer pulses its device through the `vibrate` function its creator supplied, and returns false when there is none.

`lunette/drops` is a broker for the end of a grab. The interaction provider emits a drop whenever a grab ends. A surface that moves a panel on its behalf, such as a titlebar, carries the panel's `kind` and `source`, so a listener finds the panel with `panels:forSource`. The desktop's pose memory, arrangement save, and arrangement exemption hear drops only here, so a replacement that carries surfaces must emit a drop when a grab ends.

### Lasers

A hand has one laser owner at a time. `attach` answers a laser for each hand, and a laser handle names its hand and pointer; the provider keeps the rest. The provider smooths each laser's ray with an adaptive low-pass filter before the pointer sees it; picking, delivered coordinates, and drawing use the same filtered ray, and the grab pose, buttons, and scroll are unfiltered. History resets on tracking loss, a zero ray, or a gap longer than `aim.resetAfter`.

While analog trigger pressure exceeds the lock threshold over a live offered surface, the laser holds the previous ray, so pulling the trigger does not move the hit. Rotation or movement past the unlock bounds releases the hold for the rest of the pull; grip, a grab, tracking loss, a large frame gap, or the surface going away cancels it. A reader without analog pressure never locks. `lua/lunette-plugins/laser/aim.luau` and `trigger-lock.luau` define the fields, and [Pointer aim](../guide/desktop-configuration.md#pointer-aim) describes tuning.

### Panels

Giving a panel only `width` or only `height` derives the other from the source's aspect ratio and recomputes it when the source's size changes; giving both keeps the rectangle. A monitor's aspect ratio comes from its oriented logical size. A hidden panel is not drawn or picked and gives up its layer at once, but stays in `all` and `forSource`. `panel:close(owner)` asks a window's client to close without removing the panel, or dismisses a monitor's capture and removes its panel.

Scene content is clipped to the rounded corners for drawing and hits, while a granted layer stays rectangular ([Rounded scene geometry](rendering.md#rounded-scene-geometry)). A positive `curve` makes the panel part of a vertical cylinder of radius `1 / curve`, the value `Layer:setCurve` takes, with its width measured along the arc; picking, scene drawing, and a granted layer follow the same arc. Panels draw no chrome by default.

### Runtime themes

`theme:current()` returns an immutable snapshot whose revision increases only when the effective theme changes. The last live selection decides the whole effective theme; updating a selection keeps its rank and replaces its layer, and disposing it reveals the previous live selection or the base. Invalid overrides, including a font file that fails to load, raise and change nothing. `onChanged` runs after each change, not on subscription. State commits before delivery, and a change made during delivery schedules another round instead of recursing, so intermediate revisions can coalesce and a consumer refreshes from `current()`.

Consumers resolve appearance in the order base theme, global theme, provider configuration, and object options. Omitted fields inherit and explicit zeros remain. A consumer prepares new measurements before it publishes a new appearance and keeps the old appearance if preparation fails. A palette-only change keeps pointer captures; a font or geometry change cancels the captures it affects after the new appearance is in place. The provider caches one face per font specification and leaves release to garbage collection.

`lunette/themes` is a catalog broker of named complete themes and selects nothing. `register` validates and detaches the theme.

### UI panels

`lunette/ui` panels share one declared geometry for input, drawing, and inspection: top-left, y-down logical coordinates and half-open control bounds, clipped to the panel. Higher `z` wins an overlap, then later registration. A control belongs to its panel's owner unless its options name another `owner`, and a control id is unique per creation owner across the provider's live panels. `ui:inspect()` reports each live panel with its pose and size, each control with its clipped bounds, and each list, choice, or region item. `ui:newTitlebar(owner, spec)` takes the titlebar options together with `name`, `target`, and an optional `visible` predicate.

A pointer button captures the control it pressed until release or cancellation. A release activates only that control and only inside it; cancellation never activates. A control refuses a second pointer while held. Hiding, disabling, destroying, resizing, or replacing bounds or items cancels the affected captures, and `Panel:setPose` keeps them. Hover does not take keyboard focus. A text field holds valid single-line UTF-8 and edits at grapheme boundaries from `lunette.textBoundaries`. `setValue` calls no callback.

Theme overrides resolve from the global theme to the provider, panel, and control, and a control's draw hook wraps the default renderer without changing hit bounds. Each hook invocation restores pass state and transforms, including on error. Draw errors propagate to the frame boundary, and widget callback errors are reported with the control owner. `draw.depth` in `lua/lunette-plugins/ui/draw.luau` owns the depth offsets that separate backing, controls, contents, and glyphs.

Panels and controls end with their creation owners, with the provider, and at source reload. A control's focus target is registered under the UI provider and held by the control. A frozen `ui.OwnerIdentity` token identifies a creation-owner activation, and the owner and id together identify a live control. Inspection grants no authority.

### Bindings, menu actions, and layouts

The bindings provider takes presses in the `binding` phase itself, so a bound press never reaches a client. Dispatching from `desktop/input` to the broker was rejected because a bindings outage would then stop all typing. A chord matches exactly the named modifiers, in any order, so a binding for H does not fire for Control-H. A matching press runs once and is consumed; a repeat is consumed without running, and a raising `run` still consumes.

The menu broker holds actions and renders nothing. `register` returns a registration whose `update` changes the action's `enabled` and `selected` state and answers false once the action is gone. `onChanged` runs after an action is registered, updated, or removed, so a renderer lists actions again only then. `invoke(id, token)` with a listed row's token refuses a replacement that took the same id since the row was listed. `run` executes under the registering owner's protected context.

The layouts broker calls a named layout with the live panels a caller passes and holds no panels or tags. A layout takes no options from the caller; its options are the configuration of the plugin that registers it. `continuous` marks a layout the consumer applies every frame; the broker applies nothing itself.

### Tags

A tag lasts while any owner holds it, and `hold` options apply only when it creates the tag. A panel is a member while some owner holds its membership and no owner excludes it. `exclude(owner, panel)` returns an effect, so a plugin moves a window another plugin placed and the window returns when the excluding owner lets go. `remove` drops only the caller's own membership. Selection is an owner-held override: `setSelected(owner, selected)` returns the owner's one override effect, the most recent live override decides, and disposing it reveals the previous one. A panel that dies leaves its tags without a tag change, because `panels:onRemoved` announces it.

### Rules and placement

Rule sources merge in ascending precedence, so a higher precedence wins. `vocabulary.PRECEDENCE` names the shipped precedences, so a configuration places its own source relative to them ([Placement](stdlib.md#placement)). Rule property keys the placement provider does not map pass through to the resolved properties.

`lunette/placement` is the one component that depends on rules, panels, and tags. `place` returns the placement, its panel and resolved properties, and the effect that ends it. A placement ends when its effect is disposed, its owner unloads, or its panel is removed. `placement:onPlaced` hears every placement, whoever made it. The `panelOptions` hook is where a resolved property reaches a panel. The pose memory child of `desktop/adoption` writes a dropped window's pose to its `lunette.pose` property and registers the source that answers it.

### Errors stream

`lunette/errors` subscribes to `lunette.onError` for its activation, withholds identical reports for a window, and keeps the latest report. `onReport` listeners receive each delivered report. A report raised while listeners run, such as a listener's own error, becomes the latest report without being delivered, so a raising presenter cannot feed itself.

### Frame pacing and output scale

How often each window's client draws and which scale each output's clients render at are policy over `window:setFrameRate` and `output:setMode`. Each contract hands out a pure, resource-free chooser, a pacer per window or a chooser per output, and `desktop/pacing` and `desktop/scale` read the scene and apply the answers ([Pacing and scale](stdlib.md#pacing-and-scale)).

A pacer leaves a visible window unthrottled. It runs a hidden window at the `exempt` rate when the window's content type is exempt or at least the `busy` fraction of recent samples drew, and at the `background` rate otherwise. A chooser returns a rung of `lunette.scaleSteps()` from the distance to the nearest panel showing the output's clients, and moves between rungs with hysteresis, because some toolkits re-lay out expensively on each scale change. The ladder is the one the layer pool quantises to ([Rendering](rendering.md#the-layer-pool)). `@lunette-plugins/pacing/pacer` and `@lunette-plugins/scale/chooser` are the rules.

## Native API

### Events

Native events travel LÖVR's event queue, so they interleave with `lovr.keypressed` and the other LÖVR callbacks in a defined order. A module function subscribes a listener and returns the function that cancels it. Listeners run in subscription order, each under a protected call. `crates/lunette/src/events/mod.rs` declares each event once, and the subscription function and typed payload are generated from it.

An event is delivered against the snapshot of the frame it was drained in, so `onWindowClosed` hands over a dead handle that still reports the window's last values. A process that never started is reported only through `onProcessExited`. Source reload clears every native subscription.

### Handles

[Architecture](architecture.md#handles) describes the handle model. Every mutation returns `false` on a dead handle. `window:getTexture()` and `monitor:getTexture()` are valid for the current frame only, because textures rotate as the client cycles buffers; `window:stabilize()` is the persistent alternative ([Rendering](rendering.md#windowstabilize)). `win.commit` comes from a counter every surface shares and never reuses, and is 0 before the first buffer. A handle returned by `newSeat`, `newOutput`, or `spawn` is dead until a snapshot contains its object. Every read returns a fresh handle, and `==` compares two handles by what they name, so two reads of one window, or two sinks for one target, are equal. Ids remain the keys of a table indexed by handle.

`win:setFrameRate` paces the window's frame callbacks with a floor of 1 Hz ([Rendering](rendering.md#frame-pacing)). A monitor's `mirrored` reports an installed stream, which does not prove frames still arrive ([Host desktop](host-desktop.md#identity-and-lifecycle)).

### Per-window properties

The native property store keeps scalar values per window outside the Lua state, keyed by window id, so they survive source reload and hard restart. A table or a non-finite number raises. `getProperty` still answers on a dead handle, so an `onWindowClosed` handler can read what the window stored. Entries live until the window closes. Writing them to disk is policy.

`win.id` is stable for the window's life across source reload and hard restart, because the compositor thread survives both ([LÖVR integration](lovr-integration.md#restart-semantics)).

### Layer claims

The host sorts claims stably by priority and grants the top ones. Grants and revocations land on frame boundaries, never between `lovr.update` and `lovr.draw`, so a fresh claim holds nothing in the frame that made it and the in-scene quad is always available. Lua reads the outcome from `claim.granted` and `claim.layer`, which change only at the boundary before `lovr.update`. A revoked claim stays live and is granted again when a layer frees. A claim is dead only after `claim:release()`, and nothing releases a claim when its handle is collected, because other handles to the same claim may still be held. Requested sizes are quantised up to the ladder ([Rendering](rendering.md#the-layer-pool)).

### Scene rendering

`lunette.setSceneEnabled(false)` stops `lovr.draw` and leaves the scene out of the frame, while the headset frame and composition layers are still submitted. The change applies at the next frame boundary, and the value survives source reload. Everything drawn in `lovr.draw` belongs to the configuration, so the decision is the configuration's. The default is on, and nothing shipped turns it off. [Skipping the scene](rendering.md#skipping-the-scene) states the mechanism.

## Reload

Source reload and hard restart keep running applications, because the compositor owns the Wayland socket outside the Lua state. Plugin instance reload is separate and replaces one activation. [Architecture](architecture.md#survival-across-lifecycle-events) tabulates what each event keeps.

`lunette.reload()` performs a source reload in the current Lua state, in this order: it shuts down plugin runtimes and retires the contract epoch, clears native event subscriptions, clears the configuration's LÖVR callbacks and `lovr.lun*` handlers, removes unprotected entries from `package.loaded`, and runs `main.luau` and then `lovr.load` with the startup `arg`. The LÖVR modules, XR session, GPU objects, compositor, clients, globals, and the Lua state remain. `crates/lunette/src/reload.rs` lists the protected `package.loaded` roots and the cleared callbacks. Plugin effects are the only cleanup a reload runs.

`lunette.reload()` returns `true`, or `false` and a message, and never raises. A reload that fails after `main.luau` starts leaves whatever the failed run installed; safe mode is only for startup. A reload requested during a reload or from inside a plugin callback is refused.

LÖVR's own `lovr.event.restart()` requests a hard restart. LÖVR takes it after the frame's callbacks return, so several requests in one frame are one restart. The host shuts down plugin runtimes and clears native subscribers before the state closes ([LÖVR integration](lovr-integration.md#restart-semantics)).

## Errors

Three kinds of callback run under a protected call: `lunette.on*` listeners, plugin initializers and inverses, and handlers that a Lua dispatcher protects and reports through `lunette.reportError`. An error in one is logged with its traceback and sent to every `lunette.onError` listener, and execution continues with the next listener, drain step, or handler. `crates/lunette/src/callback_error.rs` is the native boundary; it does not rate-limit. The frame, surfaces, and panels providers report each raising handler through `lunette.reportError`, so one handler's error does not stop the error display that draws after it. A plugin failure during a drain is reported with a context naming the definition and instance. An instance waiting for a provider is logged, not reported.

LÖVR's own callbacks are not protected by the host. An error in `lovr.update` or `lovr.draw` unwinds to `boot.lua`'s handler, which without a `lovr.errhand` ends the process with status 1. The frame provider protects every handler bound through it, and a configuration that assigns `lovr.update` or `lovr.draw` itself protects its own body.

The native layer owns one recovery path: if `main.luau` fails to load, safe mode starts. The trigger wraps `lovr.boot`, which raises for a source that will not mount, a missing `main.luau`, a raising `conf.luau`, a syntax error, an error at the top level of `main.luau`, and an error in `lovr.load`. Safe mode replaces whatever callbacks the failed configuration installed and shows the load error on a panel, with a laser, a terminal launcher, and a reload key. `crates/lunette/src/safe_mode.luau` is compiled into the binary, requires only `lunette`, and lists the terminals it tries; it advances to the next only when spawning the current one fails.

## lunctl

`lunctl` sends a Lua chunk to the running session over the Unix socket `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600, inside a directory lunette creates at 0700. The session evaluates the chunk on the Lua thread between frames within a time budget and sends the result back.

The directory enforces the permission: a socket inode is created with `0777 & ~umask`, `fchmod` on a socket descriptor does not reach the inode, and loosening permissions after `bind` leaves a window for a connection. `$XDG_RUNTIME_DIR` is checked for the same property at startup. There is no network transport.

A chunk resolves a free name from the globals and then from loaded modules, trying the name as written and then under `@`, so `lunette` finds `@lunette`. A name the chunk assigns becomes a global for later chunks. The exit status distinguishes a chunk that ran, raised, did not compile, exceeded its budget, or returned a result that cannot be represented, from a session that did not evaluate it or cannot be reached, and from wrong usage; `crates/lunette/src/bin/lunctl.rs` defines the codes. `LUNETTE_CONTROL=off` disables the socket.

## Language binding

The API is bound with `mlua`, which creates the session's Luau state and owns it for the session. LÖVR steps the same state through the raw C entry points. Luau has no FFI, so a configuration reaches native code only through LÖVR and `lunette`.

## Decisions

### mlua on Luau

A Lua mistake must raise a catchable error rather than crash the window manager, and mlua's per-call cost is negligible beside a compositor frame. Luau lets the standard library and configurations be statically checked. LuaJIT is not a build mode, because the standard library's annotations do not parse there.

### Control socket over Lua eval

awesome's remote Lua evaluation is a large part of its usability, and `lunctl` keeps it with a 0600 Unix socket instead of the session D-Bus, an explicit switch, and full serialisation. The plugin API is an in-process composition mechanism and does not narrow the remote protocol.

### LUNETTE_CONTROL fails closed

Only an unset, empty, or `on` value enables the socket. An unrecognised value is most likely a misspelt `off`, and opening a socket that evaluates arbitrary Lua on a warning nobody reads was rejected.

### The lunctl time budget is best-effort

A chunk runs under a Luau interrupt callback that raises once the deadline passes, at the next safepoint. A `pcall` in the chunk can catch it, and a loop in native code never reaches a safepoint. A hard bound would need a watchdog that aborts the process, which takes every client with it, so it is not built.

### lunctl refuses what it cannot represent

The serialiser errors on functions, coroutines, foreign userdata, non-scalar keys, and cycles, naming the path, rather than falling back to `tostring`, which is the defect in awesome's remote control. Shared subtables are duplicated and a node cap bounds the result. Traversal is raw, so metamethods cannot change what is reported. A reply too large for one message is reported as `Reply::Oversized` rather than by closing the connection, which the client would misreport as an unreachable session. A handle serialises as its kind and session identity, never an address.

### Per-window state lives in a native store

Source reload recreates configuration locals, but a pose or size placed by hand cannot be derived again. The store lives outside the Lua state and holds scalars only; a caller that needs structure encodes a string. Serialising arbitrary Lua values across reload was rejected because it fails on functions, coroutines, and handles.

### Safe mode is compiled in

A broken installation is one reason `main.luau` fails to load, so safe mode reads nothing from disk and requires only `lunette`. It solves its own ray-plane intersection rather than using the panels provider; the duplication is the price of always working. Installing it as a file under `$SYSCONFDIR` was rejected because it fails in exactly that case. Safe mode wraps `lovr.boot` rather than defining `lovr.errhand`, because `lovr.boot` is the boundary whose failure means the configuration did not start, and `lovr.errhand` belongs to the configuration.

### The declarations are generated from the registration

Luau resolves a require to a file and a definitions file declares only globals, so `lua/lunette/init.luau` is what the checker reads for `require '@lunette'`. Each member is declared beside its Rust closure, and `LuauType` derives its Luau spelling from the Rust type, so the declaration cannot drift from the registration. A hand-written stub was rejected because nothing would check it.

### An event is subscribed to, not assigned

An event has several listeners, the configuration and the libraries it loads, and an assigned callback gives each event one slot. A module function also types its handler, which a callback on the `lovr` global cannot. Assigned `lovr.lun*` callbacks and assignment on the module table were rejected because both keep the single slot.

### A Lua dispatcher reports through the native boundary

`lunette.reportError` lets a Lua dispatcher report a handler's error as a raising callback is reported, and continue. Reporting through `lovr.log` alone was rejected because no `onError` listener would hear it. Raising was rejected because it stops the later handlers, including the error display.

### Plugin failures are reported, not raised from the request

One drain loads and unloads many instances, so raising one instance's failure from another's request blames the wrong caller. An operation a caller performs directly, such as `effect:dispose()`, raises its own failure.

### A published service is a view that its provider's activation revokes

Handing consumers the provider's own table was rejected: a reference kept past unload would reach torn-down state, every provider would need its own liveness guard, and consumers would share one mutable table. The view checks the provider's activation, not the consumer's, because a consumer's inverses call services while the consumer unloads, and dependents always unload before their providers. The view checks reads instead of wrapping methods, because a wrapper adds a stack frame that would misattribute errors raised at level 2.

### Consumer resources are released on the consumer's owner

Registering the release on the provider's context was rejected because one failing inverse would quarantine the provider for every consumer. Owner-scoped changes are overrides rather than reverts, because a revert's outcome depends on unload order and can restore an ended owner's value. A taken name raises, because replacing or sharing the registration would end or share a resource another owner still holds.

### The plugin runtime does not defend against a malicious plugin

Every plugin runs in the configuration's Lua state with the whole `lunette` API. The runtime's checks catch honest mistakes and stale handles; they are not a security boundary. Sandboxing would need a Lua state per plugin and a narrowed API ([Overview](overview.md#non-goals)).

### A child is enabled when it is installed

`Context:child` enables its instance, matching Cordis's `ctx.plugin`, because every caller would otherwise enable it at once. A conflicting reservation raises in the parent's initializer and fails the parent.

### Plugin calls take named fields

A plugin-system call whose positional arguments would not say what they are takes a table of named fields, which also lets the facade reject a misspelt field. An owner-first call with one self-describing argument stays positional, as do surface callbacks that follow LÖVR's ray conventions. `Definition<C>` erases the context and publisher to `never`, because a recursive `Context` stops `Context:child` from checking its configuration.

### A declaration is a list of capabilities

`Context:require` and `Publisher:provide` find a service by capability identity, so a name for each declared capability would reach only the runtime manager's details, beside the contract it repeats. The facade keys each capability by its contract for the native graph. A contract carries a `version` rather than a `schema`, because `schema` names a plugin's configuration descriptor in the same declarations; the native `plugin.contract` keeps its own term.

### One owner rule for every acquisition

`Context:acquire`, `Context:acquireDeferred`, and `Context:resource` accept the same owners: the provider's own context or a checked dependent. The `Owner` type exposes no method, because an `effect` method on the owner would register a resource without the check, and nothing would make a provider call `checkOwner` first.

### Configuration types and validation share one descriptor

A runtime schema beside hand-written types was rejected because the two diverge. Preflight rejects invalid settings before acquiring resources but cannot guarantee that an initializer succeeds.

### Composition has one start path

`plugin.compose` needs only the facade, so a configuration composes its own list without the desktop. A second start path that validated at activation was rejected because the two would disagree on when a bad option fails.

### A typed patch is made from the definition

`plugin.configure(id, target)` returns a function of the configuration. Inferring from the definition and the literal in one call widens literal options such as `hand = 'right'` to `string` and reports a correct call as an error. The patch carries `target`, and composition raises when the entry with that id is made from another definition, because the target only supplies a type and a mismatch would check the options against the wrong entry. The shipped desktop's settings are a typed table keyed by entry id over the entries' own descriptors; they restate the configurable part of the entry list, which a test keeps in step, and an inserted entry configures itself through its insert's `config`.

### Frame dispatch and the surface list are contracts

A configuration-local callback registry was rejected because a plugin could reach it only by copying the file. Phases name why a handler runs where it does, so a new handler need not read every other consumer's order numbers. The `binding` and `delivery` phases let a hotkey consume a key before it reaches the target.

### The checker reports a capability with an unknown service type

`crates/lunette-lovr/src/analyze.cpp` reports calls whose result is a capability at `unknown`. Making the omission a type error in the facade's signature was rejected: a type function on the return type pushed every `Context:require` past the checker's complexity limit, and one on the parameter crashed the vendored solver across modules.

### A keyboard is laid out from keys

Keys carry `x`, `height`, and spacers, as keyboard-layout-editor's format does, so split keyboards, tall keys, and arrow clusters can be written. A uniform grid was rejected because it expresses none of them. An action is a union discriminated by `kind`, and `custom` lets a hook give a key a meaning the provider lacks.

### The keyboard contract is what consumers call

Legend lookup, latch and lock sets, rows, and style stay with the provider; a provider hook may name the provider's own `Board` type where a contract may not. A keyboard has no programmatic key or text methods and no per-keyboard rows or style: consumers press it through its surface, a plugin that types sends text through its own focus source, and every substitute provider would otherwise implement methods nothing calls. Route changes clear modifiers at once so a modifier chosen for one receiver cannot reach the next. `Keyboard` restates the surface fields rather than intersecting `Surface`, because an intersection holds two function types for `setPose` and makes calls ambiguous; `vocabulary.Movable` exists for the same reason.

### Hooks cover what wrappers cannot

The keyboard's `onKey` and `drawKey`, interaction's `drive` and `constrain`, and the laser's `draw` reach behaviour a wrapper cannot, because the provider calls itself through closures or from a bulk draw. A provider module that exposed an unpublished `build` for a plugin to wrap and publish under the same contract was rejected: no plugin wrapped a provider, and a wrapper changes only what reaches the service from outside. A `pick` hook was not added because `drive` can use the picking module. A whole-keyboard draw hook was not added because `style` covers the plate.

### Haptics reach a pointer through its creator

Only a pointer's creator knows the device. A separate feedback contract keyed by pointer was rejected as one more agreement for one function.

### Pointer buttons are a map

`Input.buttons` maps each held pointer button to true, so a right click or a remapped trigger needs no new provider. Which controller button holds which pointer button is device knowledge, so it is the laser's `buttons` option. A pointer's grab offset, two-handed partner, and pressed sink stay private, because exposing them would oblige every replacement to reproduce them.

### Layouts are a broker

A contract per layout, varied by replacing its provider, was rejected: it allows one layout at a time and shapes the contract like its first implementation. A layout is chosen by a name that a configuration carries. A tag carries no layout: a per-tag override was removed because no shipped plugin set one, so `desktop/arrange` applies its one configured layout to every tag.

### Drops are a broker of their own

Announcing drops through panels was rejected because interaction would require panels only to emit. Putting the event on the interaction contract was rejected because every listener would then go down with an interaction outage. Pose memory is a child of `desktop/adoption`, so a replacement interaction does not have to know about it.

### A broker announces its own changes

A renderer of a registry learns of a change from the registry. Polling `list()` every frame and comparing the rows was rejected because the broker already knows when its state changes. Every notification takes a listener table, so a later field, such as the tags contract's `tag` filter, needs no new signature.

### Overrides return effects and take their value

An owner-scoped override returns the effect that ends it, so selecting a tag and hiding a panel undo the same way. A single-field option table such as `{ hidden = true }` was replaced by the value itself, because the table carried no second field. Handles keep `destroy` and effects keep `dispose`: a handle is a resource the caller uses, and an effect is only its ending.

### Focus is a contract of its own

Keyboard routing is separate from interaction, so a keyboard or a local receiver needs no pointer provider. [Input](input.md#decisions) records the routing decisions.

### Decorations are a consumer

A decorator broker in the panels provider was rejected because the panels contract's listeners already give a consumer what it needs.

### Tags are held and excluded

`hold` shares a tag among its holders, so entries need no start order. Letting any owner remove any membership was rejected because the change would not end with its owner.

### Placement is a contract of its own

Placement is the integration component of section 6.5 of the Cordis paper. Mapping properties to panel options inside rules was rejected because rules would then require panels and tags. Placement announces every placement, so a plugin that places windows itself is arranged like an adopted one.

### Presenters are consumers of one error stream

A contract that carried a quad's position was rejected because a notification presenter would have to fake it.

### Pacing and scale hand out choosers

A rule with history or hysteresis needs state per window or output, and a chooser owned by its caller avoids telling the service when each one ends. A service that applied rates itself was rejected because reading the scene is a separate choice from the rule.

### A window names its output and its latest commit

Scaling by nearest panel needs a window's output, and pacing needs to know whether a client drew; both are mechanism. Comparing textures across frames was rejected because a texture lives for one frame and a client alternating two buffers repeats them.

### Theme selection has a stable provider

The theme service is separate from the replaceable selector, so disabling the selector restores the base without removing a service the recovery UI requires. Last-live arbitration over whole themes avoids mixing palettes field by field. Faces are released by garbage collection, because recorded passes hold their own references and deterministic leasing cost more than the few faces a session loads.

### Themes are an open catalog

A plugin calling `theme:select` with its theme was rejected because it would contend with the selector and never appear among its choices. Entries are complete themes so none silently inherits the base.

### UI owner identities are frozen tables

A numeric counter restarts after replacement and can repeat an owner and control id. Control ids are namespaced by owner rather than by panel, because one owner may build controls across panels and several owners may contribute to one.

### Joined frames expose a narrow optional relationship

The target owns body drawing and knows whether it is eligible to join, so generic surfaces need not expose layer or curve state. A general container or transform API was rejected as unneeded. Dormant attachments persist so temporary layer grants or hiding cause no per-frame churn ([Rendering](rendering.md#joining-follows-the-actual-rendering-path)).

### Grapheme segmentation is native mechanism

Extended grapheme rules are a correctness tail, so the native helper uses `unicode-segmentation` rather than a Lua implementation. Editing policy stays in Lua.

### State a frame reads is not also announced

A claim's grant and a window's title are fields a consumer reads every frame. `onLayerGranted`, `onLayerRevoked`, and `onTitleChanged` were removed because nothing subscribed to them, and two ways to learn one fact let the documented one drift from the one in use. An event returns with the consumer that needs it.

### Handles compare by what they name

Every read returns fresh userdata, so raw equality told two reads of one window apart and every caller compared ids, with a sink needing a different id per domain. `__eq` compares what two handles name. Ids remain, because a table keyed by handle compares keys raw.

## Known gaps

Native events are named `lun*` inside LÖVR's event namespace. A collision with a future LÖVR event is unlikely but not excluded.

`lunctl` has root-equivalent access to the user's session; anything that can write to the socket controls the session.

Source reload and hard restart run no cleanup for Lua modules outside the plugin runtime.

An error in a LÖVR callback that no Lua dispatcher protects ends the session with status 1. Recovering in the host would need each callback called under its own protected call, and a frame that unwinds between `lovr.headset.getPass` and `lovr.headset.submit` would still have to end the XR frame it began. A `lovr.errhand` that returns the previous loop skips the rest of the frame, including its submit.

A monitor panel cannot hold a composition layer, because `lunette.claimLayer` takes windows. The curved arc mesh and rounded scene geometry have not been seen on a GPU-backed session, and real font loading in installed and development sessions is unverified.

Text shaping, bidirectional editing, and IME composition are absent from the UI toolkit, and draw hooks cannot make arbitrary pass misuse safe. [Input](input.md#known-gaps) records the routing limits.

## Deliberately left open

Contract authorities are a naming convention and are not authenticated. Any module can declare a contract under any authority, including `lunette`, and the first declaration in an epoch holds the name and schema. Binding an authority to the package that may declare under it is left to plugin packaging and distribution, #39.
