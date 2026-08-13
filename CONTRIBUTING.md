# Contributing to lunette

## What this is

lunette is an XR window manager and Wayland compositor. It runs as an OpenXR overlay, spawns Wayland applications inside itself, mirrors the user's monitors, and presents both to Lua as textures and input sinks. The host is a Rust binary that dynamically links LÖVR; the scripting layer is Lua on LuaJIT; the compositor is smithay, vendored from WayVR.

The project is licensed GPL-3.0-only, because it uses WayVR's GPL-3.0-only code. Contributions are accepted under that licence.

<!-- contributing-templates: files=general.md,rust.md @ 57e7c55206a089254c37b212bb3ad43574cde20c -->

## Current status

The workspace builds, links LÖVR, and opens a window running a Lua configuration. Nothing above that exists yet: no compositor, no capture, no standard library. The first milestone is a vertical slice whose purpose is de-risking two specific unknowns; see [docs/roadmap.md](docs/roadmap.md).

## Repository layout

The layout is recorded in [docs/build-and-development.md](docs/build-and-development.md). In summary:

```
crates/lunette/                       the binaries: lunette and lunctl, Lua injection, frame orchestration
crates/lunette-compositor/            smithay; vendored fork of WayVR's backend/wayvr
crates/lunette-lovr/                  cmake build and FFI surface for LÖVR
crates/lunette-capture/               wrappers over wlx-capture and HidProvider
crates/lunette-generate-definitions/  generates etc/lunette/definitions.luau from lovr-docs
lua/                                  the mullion standard library
etc/lunette/                          the generated Luau definitions
etc/xdg/lunette/                      the default configuration
vendor/lovr/                          submodule, LÖVR with lunette's patch branch (recursive)
vendor/lovr-docs/                     submodule, the API metadata the definitions generate from
vendor/mlua/                          submodule, mlua with lunette's Luau ABI patches
docs/                                 the design specification
inspiration/                          reference checkouts, gitignored
```

`lunette-compositor` must not depend on `lunette-lovr`. Logic-headless testing depends on that separation.

## Documentation

`docs/` is the design specification, not a description of the code. It is normative. A change that alters behaviour described there updates the relevant document in the same change.

`docs/decisions.md` records decisions with their reasoning, known gaps, and deliberately-open questions. A change that reverses a recorded decision updates that file and states why. This exists so that settled questions are not reopened by accident.

The documents use a plain technical register: short declarative sentences, active voice, no second person, no emphasis formatting. New documentation matches it.

## Vendored code

`crates/lunette-compositor` is a hard vendor of WayVR's `backend/wayvr`. It carries WayVR's copyright and licence, and its provenance is stated at the top of each file taken from it.

Vendored code is exempt from the house style in this document until it is rewritten. Reformatting it wholesale destroys the ability to diff against upstream when a fix is worth taking. Bring a file up to house style when a change touches it substantially, not in drive-by churn.

`wlx-capture` is a git-pinned external dependency, not a vendor. Fixes to it go upstream. Upstream is the `wlx-capture` directory of the WayVR monorepo, not the standalone `galister/wlx-capture` repository: that repository stopped at 0.5.4, which pulls `ashpd` with an `async-std` executor and a personal fork of pipewire-rs, while 0.6.0 removed both and exists only inside the monorepo with no independent tag. The pin therefore names a WayVR revision, and repointing it at the standalone repository is a regression rather than a tidy-up.

## The LÖVR fork

`vendor/lovr` is a submodule pointing at `philpax/lovr`, a fork of upstream LÖVR, with lunette's patches on its `lunette` branch. That branch is rebased onto upstream `dev` rather than merged, so the patch set stays a readable series. Its own `deps/` are nested submodules, so clone recursively.

Patches to LÖVR stay narrow and additive: new accessors, new struct fields, new build options. No behavioural changes to existing paths, with one exception: a patch that fixes an upstream defect changes the path it fixes, and says in its message which defect and why the fix belongs upstream rather than here. Each patch is shaped as an upstream pull request. The patch set is listed in [docs/lovr-integration.md](docs/lovr-integration.md), which also records what has been proposed and what has not.

## Lua conventions

There is no upstream Lua template. These conventions apply to the `mullion` standard library and to example configurations.

- Target Luau, which accepts Lua 5.1 syntax and adds type annotations. Do not use LuaJIT-only or 5.2+ syntax that Luau rejects, and no `goto` (Luau has none).
- Write a contract's data properties as `read`. Luau compares a read-write property invariantly, so `pose: Mat4` does not satisfy `pose: Mat4?` and a type carrying no such field does not satisfy an optional one. A read-only property is compared covariantly and both do. `interaction.Surface` is the worked example.
- Name the contract as a method's receiver, in the contract and in the implementer both. A receiver is a parameter and parameters are contravariant, so an implementer naming its own type there cannot answer the contract; `any` on both sides typechecks and checks nothing. Where the tiers forbid naming it — a tier 1 module cannot require a tier 2 one, and naming a type means requiring the module that declares it — put the vocabulary in a types-only module, as `mullion.interaction.types` is.
- Model a closed set as a union, and discriminate it where its members differ. A field that tells the arms apart is what narrows the others: testing `panel.kind` is what reaches the `lunette.Window` behind a window panel.
- Fix a wrong declaration in the metadata or the generator, never in the calling code. Every workaround for a declaration that misdescribes LÖVR has changed behaviour: returning `true` from `lovr.quit` to satisfy its declared return vetoed the quit, and spelling an identity matrix out as sixteen numbers followed from an ambiguous constructor.
- Use camelCase for functions and fields, matching LÖVR. Users write LÖVR code, and a second convention in the same file is friction with no benefit.
- The standard library uses only the public `lunette` API. If it needs something the API does not expose, that is a defect in the API, not grounds for a private path.
- Keep the two roots distinct. `lunette` is native mechanism; `mullion` is policy implemented in Lua. Do not add policy to `lunette` or expect mechanism from `mullion`.
- The lunette API is available only in the main Lua state. Do not use it from `lovr.thread` or `lovr.task` states.
- Every module is safe to `require` twice, and registers a teardown hook. Soft reload discards the Lua state; a module that leaks timers, signal connections, or coroutines across a reload is a defect.
- Never assume a handle survives a frame. Check `handle.dead` before use.
- Never cache the result of `window:getTexture()` across frames. Textures rotate as the client cycles its buffers. Use `window:stabilize()` when a persistent texture is genuinely wanted.
- Raise errors normally. Callbacks run under `xpcall`, and the handler reports them. Do not swallow errors to keep a frame alive.
- The file-size threshold is around 500 lines, lower than the Rust threshold because Lua modules carry less ceremony.
- Comments end with a period. Headings and titles use sentence case.

### Formatting

`stylua.toml` configures StyLua for the tree, and `stylua --check lua etc/xdg/lunette` is one of the standing checks. The settings describe what the tree already did rather than imposing something new: two-space indent, single quotes, no parentheses around a call's single string or table argument, and a 120-column width, which is where the code already sat.

`syntax = "Luau"` is set because the tree carries type annotations that the Lua grammars reject.

### The Luau static check

`lunette check` typechecks `lua/mullion` and the shipped configuration against the generated definitions. It is the same in-process checker the user-facing command and `make check` run, so the two paths cannot drift.

The checker is strict mode. `etc/lunette/definitions.luau` declares the runtime: it is generated from lovr-docs by `crates/lunette-generate-definitions`, so a missing `lovr` field is fixed by correcting the metadata or the generator rather than by hand-editing the output. Luau declares the standard functions itself, and there is no `io` at runtime, so neither is declared here. mullion modules carry their own types.

`lua/spec/suite.lua` and `lua/spec/expect.lua` are checked: they are ordinary modules that happen to be used by tests. The spec files themselves are not, and neither is `lua/spec/runner.lua`. The runner requires by a name it computes from a directory walk, which is the one require form the checker cannot follow. The spec files construct the windows, seats, and sources they drive the standard library with as the smallest table each case needs, and the handle types are exact, so checking them would mean either building a whole handle per case or casting each one. Both make the tests worse at the thing they are for. A case that needs a real shape gets it from the module under test.

The check catches the two defect classes static analysis exists for: a local referenced before its declaration (`Unknown global`), and an accidental global (`GlobalUsedAsLocal`).

## General conventions

### Correctness over convenience

- Model the full error space—no shortcuts or simplified error handling.
- Handle all edge cases, including race conditions, signal timing, and platform differences.
- Use the type system to encode correctness constraints: newtypes, builder patterns, type states, lifetimes. Never use a bare string or integer where the domain has a meaning for it; a recognised closed set of values rides as an enum, not as bare strings.
- Prefer compile-time guarantees over runtime checks where possible.
- Use message passing or the actor model to avoid data races in concurrent code.
- **Never silently drop content you can't represent.** When adapting data between formats, return an error for anything the target can't express. A caller may then choose to ignore it; silent data loss is a correctness bug, not a convenience.
- Validate at each layer the data crosses, not only where the bug happened to surface. One check is bypassed by the next code path, refactor, or test double; the goal is to make the bad state structurally impossible, not locally absent.
- Getting the details right is really important!

### User experience as a primary driver

- Provide structured, helpful error messages that can be rendered with an appropriate library at a later stage.
- Make progress reporting responsive and informative.
- Maintain consistency across platforms even when underlying OS capabilities differ. Use OS-native logic rather than trying to emulate Unix on Windows (or vice versa).
- Write user-facing messages in clear, present tense: "Frobnicator now supports..." not "Frobnicator now supported..."

### Pragmatic incrementalism

- "Not overly generic"—prefer specific, composable logic over abstract frameworks.
- Evolve the design incrementally rather than attempting perfect upfront architecture.
- **The rule of three**: don't abstract until you've seen the pattern three times. Three similar lines beat a premature abstraction, which is harder to remove than it was to add.
- Don't build for hypothetical future requirements.

### Dependencies

- Neither reflex is right: reaching for a dependency for something trivial and handrolling something with a long correctness tail are both mistakes, and the second is the more expensive one.
- Handroll it when it's small, self-contained, and you can see the whole problem — a builder, a wrapper, a couple of pure functions.
- Take the dependency when the problem has a tail you'd otherwise discover in production: dates and timezones, Unicode, text encodings, compression, TLS, anything cryptographic. Never handroll cryptography.
- Prefer an existing dependency (including one of its feature flags) over a new one, and a focused library over a framework you'd use 5% of.
- Where the project documents a chosen stack, use it rather than silently introducing an alternative to something already covered.
- When it's genuinely unclear, ask rather than picking silently. Either direction is cheap to change early and annoying to change late.

### Boundaries and compatibility

- A library never reads environment variables. Configuration — keys, URLs, feature flags, paths — arrives as parameters, and only the application entry point reads the environment. Otherwise the library can't be tested without manipulating the environment, and it's silently coupled to a deployment.
- When changing anything serialised to disk or sent over a wire, walk the whole version matrix: old reader with new data, new reader with old data, and **old writer with new data**.
  - That third case is the one that gets missed. A default lets an old reader parse new data, but an old writer then drops the fields it doesn't know about on write-back — which corrupts the file rather than failing on it.
  - Bump the format version when you add the field, not when you first depend on it.

### Functional core, imperative shell

- Keep decision logic in pure functions that take data in and return data out. Keep I/O, concurrency primitives, and orchestration in a thin shell at the edges.
- The shape is gather, then process, then persist: the shell collects the inputs, the core decides, the shell writes the result. A core function that reaches out to read something mid-decision is the thing this is meant to prevent.
- Isolate coupling to the outside world — filesystem, clock, network, subprocesses, devices — behind a small seam: a trait, an interface, a dependency struct, with a production implementation and a test fake. Tests are deterministic because they substitute the fake, not because they clean up after the real thing.
- The payoff is testability. A pure core needs no fakes at all, and a thin shell has little logic left worth mocking. When a test needs elaborate setup to reach the behaviour it's checking, that's usually the code's shape talking, not the test's.

### Code organisation

The language-specific files set the file-size threshold and the naming conventions; these apply everywhere.

- Name a file for what it holds, not for a category. No `utils`, `helpers`, `common`, or `misc` — they become dumping grounds, and nothing stops unrelated code being added to a file whose name claims nothing. A file named for string formatting, or date arithmetic, or API error handling is one it's hard to put the wrong thing in. (Each language file gives the casing to use.)
- Within a file, put the public API first, then the private implementation below it: constants, helpers, and internal types. Order the private items by use, so each appears roughly in the order the public API reaches for it (topological order).
- Split a file along natural seams — distinct data types, feature groups, functional areas — not arbitrarily at the line limit. A cohesive single-concern file that slightly exceeds the threshold beats a fragmented one.
- Group a wide folder into subfolders by domain or role. A flat folder of 20+ files is a signal that subfolders are wanted.
- Test files follow the same thresholds as the code they test.

### Testing

- Test comprehensively, including edge cases, race conditions, and stress tests.
- Pay attention to what facilities already exist for testing, and aim to reuse them.
- When fixing a bug, add the failing regression test first, then make it pass.
- **Use real instances of what you control, and fakes for what you don't.** Your own database or filesystem is a managed dependency: talking to it is an implementation detail you can refactor freely, so test against the real thing. A third-party API, an SMTP server, a message bus is unmanaged: that conversation is observable behaviour, so put it behind a fake.
- **Don't mock what you don't own.** Wrap the third-party library in your own thin interface and substitute that, rather than mocking the library's own surface. It makes the test simpler and the design better.
- Never add a method to production code that only tests call. Cleanup and inspection helpers belong in test utilities.
- Wait for conditions, not for durations. Poll for the state you're expecting with a timeout, rather than sleeping long enough that it's *probably* ready — the latter passes locally and fails in CI. A fixed sleep is right only when the thing under test is itself about timing, like a debounce, and then the comment says why that duration.
- Clean up long-lived resources: containers, VMs, processes, cloud objects. Don't bother scrubbing database rows and log entries — perfect data cleanup is a fool's errand that makes multi-step integration tests nearly impossible. A test that needs pristine state should mint unique identifiers instead of depending on an empty table.
- Don't write a test that only exercises serialisation or a derived implementation. A round-trip earns its place only when it guards a real wire: a versioned payload, a public API, or a file format.
- No personal names in fixtures, and never the author's own identity. Anonymise every test and fixture to invented placeholders; do not seed one from any real person's name, handles, or biographical details, even when real data reproduces the behaviour under test. Reproduce the *shape* of what you observed, never the actual content.

Where a function has a property worth stating, prefer a property-based test over a handful of examples. Reach for the strongest property that applies — roughly, in increasing order of strength: doesn't crash, preserves the type, holds an invariant, is idempotent (`f(f(x)) == f(x)`), round-trips (`decode(encode(x)) == x`). An oracle property, where a new implementation must agree with the old one, is the tool for a rewrite.

Two ways a property test can look fine and test nothing. It can be tautological, comparing an expression against itself. Or it can restate the function's own logic in the assertion, in which case a bug in your reasoning appears in both halves and cancels out. Include the degenerate cases — empty, single element — explicitly rather than trusting the generator to find them.

### Documentation

- Use inline comments to explain "why," not just "what".
- Don't add narrative comments in function bodies. Only add a comment if what you're doing is non-obvious or special in some way, or if something needs a deeper "why" explanation.
- Module-level documentation should explain purpose and responsibilities.
- Comments and docs describe the present state. Reserve past-tense narration for the rare case where history explains a standing "why".
- Keep the user-facing docs in sync with the code. Where a document restates something the code owns — a config default, an example config file, a generated reference, an API surface — name the code as the source of truth and update the document in the same change. A code change that lands without its doc update isn't finished.
- Better still, generate the document from the code and check it in CI. Don't rely on anyone remembering.
- **Always** use periods at the end of code comments.
- **Never** use title case in headings and titles. Always use sentence case.
- Always use the Oxford comma.
- Don't omit articles ("a", "an", "the"). Write "the file has a newer version" not "file has newer version".

The two sections that follow are the Rust template. They apply to Rust code in this repository. The Lua conventions above apply to Lua.

## Code style

### Rust edition and linting

- Use Rust 2024 edition.
- Format with **nightly rustfmt**: `cargo +nightly fmt --all`. `rustfmt.toml` opts into `imports_granularity = "Crate"` and `group_imports = "StdExternalCrate"`, which are nightly-only — stable rustfmt prints a warning about each and then silently skips them, so a stable-formatted file is *not* equivalent to a nightly-formatted one.
- Ensure the following checks pass at the end of each complete task (you don't need to do this for intermediate steps). `make check` runs all of them, and `.github/workflows/ci.yml` runs the same list on every push, so a check added here is added to both:
  - `make check-format`
    - `cargo +nightly fmt --all -- --check`
    - `stylua --check lua etc/xdg/lunette` — the Luau formatter (see [formatting](#formatting))
  - `make check-rust`
    - `cargo clippy --workspace --all-targets --all-features -- -D warnings`
    - `cargo clippy --workspace --all-targets --no-default-features -- -D warnings`
    - `cargo test --workspace`
    - `cargo test --workspace --no-default-features`
  - `make check-definitions`
    - `cargo run -p lunette-generate-definitions -- --check` — regenerates `etc/lunette/definitions.luau` into memory and fails if it differs from what is checked in. It names the first line that differs. Run `cargo run -p lunette-generate-definitions` and commit the result.
  - `make check-luau`
    - `cargo run -p lunette --bin lunette -- check --definitions etc/lunette/definitions.luau $(find lua/mullion -type f \( -name '*.lua' -o -name '*.luau' \) -print | sort) etc/xdg/lunette/main.lua` — the Luau type checker over `lua/mullion` and the shipped config (see [the static check](#the-luau-static-check))
- Configure clippy's restriction lints in `[workspace.lints.clippy]` in the workspace root's `Cargo.toml`, with each crate opting in via `[lints] workspace = true`:

  ```toml
  [workspace.lints.clippy]
  unwrap_used = "warn"
  expect_used = "warn"
  ```

- The end-of-task and CI clippy commands pass `-- -D warnings`, so any warning fails those checks; a plain `cargo clippy` run reports warnings but doesn't fail on them.
- Use `cargo clippy` in place of `cargo build` — it typechecks and lints in one pass, so a separate build buys nothing.
- Iterate in debug. Reach for `--release` only when benchmarking or packaging.
- No `unwrap()` or `expect()` in production code; tests are fine. The restriction lints are configured at `warn` and `-D warnings` promotes any warning to a hard error, including inside `#[cfg(test)]`, so a test module whose cases use `expect` carries `#[expect(clippy::expect_used, reason = "...")]` — naming the lints it actually uses, with a reason stating the rule. The vendored `lunette-compositor` crate does not opt in via `[lints] workspace = true`: it carries WayVR's code, whose tests use `expect` liberally, and it is exempt from house style until rewritten.
- Never silence a lint without a concrete reason documented in a comment above it. In almost all cases the right move is to restructure the code.
- When you do suppress one, prefer `#[expect(...)]` to `#[allow(...)]`. `expect` warns once the suppression is no longer needed, so stale suppressions can't quietly accumulate as the code changes around them.

### Type system patterns

- **Builder patterns** for complex construction (e.g. `TestRunnerBuilder`).
- **Type states** encoded in generics when state transitions matter.
- **Lifetimes** used extensively to avoid cloning (e.g. `TestInstance<'a>`).
- **Newtypes** for domain types, per the general rule against bare primitives.
- **`#[non_exhaustive]`** on public types in a library crate with a stable API, so a new variant or field isn't a breaking change. Internal crates don't need it.
- **Parameter structs over long argument lists**: when a function approaches the `clippy::too_many_arguments` threshold, bundle the cohesive parameters into a struct rather than threading more positional arguments. A request struct, or a shared seam like `Engine { store, graph, clock }` that several call shapes pass along.
  - **Never** silence that lint with an `allow`. The lint firing means a struct is wanted. The one exception is a signature you don't own — an FFI shim, or a hook mirroring a foreign ABI — where the `allow` is the honest annotation.

### Error handling

- Do not use `thiserror`. Instead, manually implement `std::fmt::Display` and `std::error::Error` for a given error `struct` or `enum`. `Error::source` returns the wrapped cause where there is one, so the chain stays walkable.
- Group errors by category with an `ErrorKind` enum when appropriate.
- Provide rich error context using structured error types.
- Two-tier error model:
  - `ExpectedError`: User/external errors with semantic exit codes.
  - Internal errors: Programming errors that may panic or use internal error types.
- Every error's `Display` leads with a `<context>:` prefix naming the subsystem or operation it belongs to, then the cause: `event store: …`, `lua: block commit failed: …`, `could not open the event log at /path: …`. Messages stay lowercase, so they compose.
  - An aggregating error prefixes its own layer's context and delegates to the inner error. A chained error then reads as nested context: `turn: lua: block commit failed: event store: …`.
  - Add resource context — a path, an id — at the layer that has it. Avoid bare "failed to {x}" glue; name the operation instead.

### Async patterns

- Do not introduce async to a project without async.
- Use `tokio` for async runtime (multi-threaded).
- Use async for I/O and concurrency, keep other code synchronous.
- Use `parking_lot::Mutex` for synchronous locks (the default); its guard is non-poisoning and must never be held across an `.await`. Reserve `tokio::sync::Mutex` for the rare guard that must survive an `.await`, since most locks are acquired, used, and dropped within a synchronous span.
- Use bounded `mpsc` channels; an unbounded channel hides backpressure.

### Logging

- Use `tracing` for diagnostic and operational logging throughout, emitting at meaningful points, not noisily.
- Install the subscriber only in binaries, and send logs to stderr.
- Operator and diagnostic programs route their output through `tracing` too. Reserve `stdout`/`println!` for genuine machine-readable command output.

### Module organisation

- Use `mod.rs` files to re-export public items; nontrivial logic lives in submodules, not in `mod.rs` itself.
- Keep module boundaries strict with restricted visibility, but prefer `pub(crate)` and `pub(super)` over `pub(in <path>)`. The `pub(in …)` form scopes to a named ancestor, which is precise but reads as a smell; reach for it only when neither `pub(crate)` nor `pub(super)` expresses the intended scope.
- Use `#[cfg(unix)]` and `#[cfg(windows)]` for conditional compilation.
- **Always** import types or functions at the very top of the module, with the one exception being `cfg()`-gated functions. Never import types or modules within function contexts, other than this `cfg()`-gated exception.
- It is okay to import enum variants for pattern matching, though.
- Re-exports follow the same rule: a `pub use` belongs at the top of the module with the imports, not beside the item it re-exports. In a `mod.rs`, the `mod` declarations come first, then the `pub use` block, so the module's public surface reads as one list.
- A path used more than once in a module gets imported at the top — the specific items, not the module — rather than repeated in full at each call site.
  - A path used once may stay fully-qualified. Unless it's unwieldy, meaning more than three module segments deep, in which case import it anyway.
  - And when the module already imports a sibling from the same parent, import the new item alongside it rather than writing it inline.
- **Always** anchor intra-crate paths at `crate::`, never `super::`. Write `crate::graph::Graph`, not `super::Graph` or `super::super::Graph`. The one exception is a test module, where `use super::*;` (pulling the parent module into the `#[cfg(test)]` block) is the idiomatic form and stays.
- Prefer a single grouped `use` statement per crate root rather than several siblings under it, collapsing shared prefixes: `use axum::{extract::State, http::StatusCode, routing::get};`, not three separate lines. Group imports into three blocks separated by blank lines: `std`, external crates, then `crate`/`super`/`self`. `imports_granularity = "Crate"` and `group_imports = "StdExternalCrate"` in `rustfmt.toml` enforce both automatically under nightly rustfmt.

### Code organisation

The general code-organisation rules apply; these are the Rust specifics.

- **The file hierarchy is the architecture diagram.** A newcomer should be able to read the directory listing and infer what the project does.
  - A subsystem with a public entry point is a folder module whose `mod.rs` states the boundary, with private submodules inside. Only `lib.rs`, `main.rs`, and genuinely cross-cutting types like `errors.rs` stay as top-level single files.
  - Avoid a top-level single file where a folder grouping is natural. If several files are semantically related, or file A is only consumed by file B, merge them.
- **The file-size threshold is around 1000 lines.** Split into a folder and re-export the public items from `mod.rs`, so consumers see a stable API.
  - Splitting is cheaper than it looks: methods on one type can spread across several `impl` blocks in different files of the same module, so there's no visibility or trait plumbing to do.
  - A large inline `#[cfg(test)] mod tests` counts toward the total. Extracting it to a sibling `tests.rs` is often the whole fix.
  - Existing oversized files are grandfathered. Split one when a change touches it substantially, not in drive-by churn.
- Shared helpers for a split test module live in its `mod.rs`.

### Control flow and state machines

- Avoid rightward drift. If a function is nesting three `select!` blocks or four levels of `match`/`if let`, extract each arm into a named function that takes a context struct. The control flow at the top level should read like an outline.
- Model each state machine as an explicit `enum` with named variants, even if only one field differs between them. Favour an exhaustive `match` plus a `transition` helper over scattered `if let` chains.
- Where a subsystem transitions through phases that own different local state (e.g. `Idle`, `Starting`, `Running`, `Draining`), extract each phase body into its own function and pass a typed context struct. This is the pragmatic version of the typestate pattern for actor-style loops; it keeps invariants local without requiring full type-parameterised phases.
- Invalid transitions should be unrepresentable at the boundary where they're consumed. If `transition()` returns `Option<State>`, the caller should never `.unwrap()` it in production — either enumerate the legal inputs ahead of time, or make the caller total.

### Platform coupling

- A file that depends on platform-specific facilities says so on the first line of its module-level docstring: `//! Linux-only: reads /proc/{pid}/cmdline.` The convention is explicit enough that a port to a second platform — or a reviewer — knows exactly what the contract is.
- The outside-world seams take the form of traits — `Fs`, `ProcessSpawner`, `GpuProbe`, `Clock` — bundled into one dependency struct that production and test construct differently. A second OS implementation then falls out of the same shape the fakes already needed.
- When a second platform does land, gate the existing impl with `#[cfg(target_os = "…")]` and add the alternative under a sibling gate; the trait definition stays platform-neutral.

### Reaching through smart pointers

- To borrow the value inside a lock guard, a `Box`, or an `Arc`, prefer `.as_ref()` / `.as_mut()` over a manual double-deref: write `state.lock().as_ref()`, not `&**state.lock()`. The named form reads as "borrow the value" rather than as deref bookkeeping. The same applies to an `Arc<dyn Trait>`: `model.as_ref()`, not `&**model`.

### Serde

- Use `#[serde(deny_unknown_fields)]` on config types, and `#[serde(default)]` on new fields so they stay backwards-compatible.
- Use `serde_ignored` when deserialising config, so a typo'd or stale field is reported rather than ignored.
- Avoid `#[serde(untagged)]` when deserialising — the error messages it produces are useless. Write a custom visitor instead.
- Reserve `#[serde(flatten)]` for the case it is genuinely for: extending a shared struct with local fields, or a `toml::Table` catch-all that preserves unknown fields across a round-trip. Note that it interacts badly with `serde_ignored` and with `deny_unknown_fields`.

### Memory and performance

- Be deliberate about when you clone and when you borrow. Share immutable data behind `Arc`/`Rc` or borrow it; where the data has a natural tree or graph shape, share the nodes rather than cloning subtrees.
- Use `smol_str` for efficient small string storage.
- Use `smallvec` for collections that are usually small, to avoid heap allocations in the common case.
- Stream data (e.g. iterators) where possible rather than buffering.

### Dependency versions

- **Applications, binaries, and workspace-internal crates: pin exactly.** Cargo's default caret range lets resolution drift between `cargo update` runs; `serde = "=1.0.219"` makes a bump a reviewable change instead of an ambient one.
- **Crates published to a registry: use the narrowest range that works.** An exact pin in a published library breaks diamond-dependency unification — if two of a consumer's dependencies pin different patch versions of the same crate, they get two copies or a hard resolution failure. Publish a range and let the consumer's lockfile do the pinning.
- Manage shared versions in the workspace root's `[workspace.dependencies]` and reference them with `{ workspace = true }`.
- Check the current version before adding or bumping a crate rather than writing one from memory.
- Comment on a non-obvious dependency choice, including a feature-flag choice made for a reason.

## Testing

### Testing tools

- **test-case**: For parameterised tests.
- **proptest**: For property-based testing.
- **insta**: For snapshot testing.
- **libtest-mimic**: For custom test harnesses.
- **pretty_assertions**: For better assertion output.
- Use `cargo nextest run` in place of `cargo test` where it's available.

### Testing conventions

- Unit tests live in the same file as the code under test, in a `#[cfg(test)] mod tests` block. Integration tests live under `tests/`.
- Never `#[ignore]` a test, and never let one silently skip. A test that cannot run in an environment is gated by a `cfg` or a feature, so its absence is visible.
- Tests must be deterministic: no real subprocesses, no real filesystem, no wall-clock sleeps, no network. Route each of those through the seam traits above and substitute the fake. Gate a fake behind `#[cfg(any(test, feature = "test-fakes"))]` when integration tests need it too.
- Compositor tests are a narrow exception to the filesystem half of that rule. A test connects its client over an in-process `UnixStream::pair()` — `Connection::from_socket` on the client side, `DisplayHandle::insert_client` on the compositor side — which binds nothing and touches no filesystem, so the rule holds unchanged for almost all of them. The few tests covering the listener itself — bind, listen, accept, and socket-path selection — may bind a real socket in a per-test temporary directory, because that code path is the thing under test and cannot be reached any other way. The exception covers the listener and nothing else: it does not license real subprocesses, real network access, or wall-clock sleeps, and the rule about waiting for conditions above still governs how a test waits for a client to map a surface.
- The exit-status test is a narrow exception to the subprocess half of the same rule. `crates/lunette/tests/exit_status.rs` spawns the real binary against a checked-in fixture configuration directory and asserts the status the process exits with. The status is a property of the process rather than a value any function returns — `boot::run` yields an opaque `ExitCode`, and the code that produces it cannot be reached without a live LÖVR Lua thread — so there is no in-process form of the test. The exception covers the exit status and nothing else: the fixtures disable the audio, graphics, and headset modules and open no window, so the run needs no display, no XR runtime, and no sound device, and it neither sleeps nor reaches the network. It does write LÖVR's save directory, which `lovr.filesystem.setIdentity` creates unconditionally: each run points `XDG_DATA_HOME` at its own temporary directory and each fixture carries a distinct identity, so the write lands inside that directory, two parallel runs cannot race to create one shared leaf, and the result does not depend on `HOME` or on the running uid having a passwd entry.
- Never call `Connection::connect_to_env()` in a test. It calls `env::remove_var("WAYLAND_SOCKET")` internally, which mutates the process environment and is unsound in a multithreaded test binary. `Connection::from_socket` is the only form tests use.
- Time is the narrow exception when everything already runs on `tokio::time`: `#[tokio::test(start_paused = true)]` plus `tokio::time::advance` gives virtual time without needing another seam.
