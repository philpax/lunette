# Contributing to lunette

lunette is a Rust host with a Luau scripting layer and a Wayland compositor. Contributions are accepted under GPL-3.0-only; patches to MIT-licensed forks retain their upstream licence. [Credits](CREDITS.md) records attribution and redistribution requirements.

<!-- contributing-templates: files=general.md,rust.md @ 57e7c55206a089254c37b212bb3ad43574cde20c -->

## Development

[Build and development](docs/development/build-and-development.md) covers setup, running the working tree, and testing. [Architecture](docs/development/architecture.md) records the boundaries that changes must preserve. The [Makefile](Makefile) owns build and check commands.

Run `make check` at the end of a complete task. Iterate in debug, use clippy for Rust typechecking and linting, and reserve release builds for packaging or benchmarking. Fix generated declarations in their metadata or generator, then run `cargo run -p lunette-generate-definitions`. Never edit generated output or work around an incorrect declaration in calling code.

Every session action must remain reachable through VR controls without a physical keyboard, mouse, or flatscreen interface. Developer tools and test runners are outside this requirement. Shipped plugins use only the public native API; a missing capability requires an API change, not a private path.

## Documentation

Each document serves one audience:

- lunette users need configuration and session workflows in `docs/users/desktop-configuration.md` and `docs/users/runtime-manager.md`.
- Plugin developers need authoring guides in `docs/plugins/`, the `lua/lunette-plugin/` facade documentation, shared guarantees in `lua/lunette-contracts/`, and plugin READMEs.
- lunette developers need build instructions, architectural constraints, and integration hazards in `docs/development/` and this file.

Keep workflows, public guarantees, consequential rationale, and unresolved limitations that affect the reader. Remove implementation walkthroughs, API inventories, default lists, test catalogs, and status narration. The pruning policy does not apply to contributor coding guidelines; retain their rules and rationale. Link to schemas, generated declarations, and checked examples instead of copying them. A short plugin topic stays in its README; internal helpers do not need separate manuals. Decisions belong beside the constraint they explain, not in mandatory trailing sections. Licensing and provenance belong in [CREDITS.md](CREDITS.md) and [PROVENANCE.md](crates/lunette-compositor/PROVENANCE.md).

A behaviour change updates the relevant workflow or guarantee in the same change. Code owns signatures, defaults, and algorithms; documentation must not create a second copy. Write short declarative sentences in the present tense, use sentence-case headings, and avoid second person and emphasis formatting. Comments explain non-obvious reasons and end with a period. Module documentation states purpose and responsibilities.

## Vendored code and forks

`crates/lunette-compositor/src/wayvr/` preserves upstream names, identifiers, formatting, and attribution so fixes remain comparable with WayVR. It is exempt from house style. Files outside that directory follow the conventions below. [PROVENANCE.md](crates/lunette-compositor/PROVENANCE.md) records the source revision and relocated fragments. `wlx-capture` is an external dependency from the WayVR monorepo; fixes go upstream, and the standalone repository is not the maintained source.

Clone submodules recursively. [LÖVR integration](docs/development/native/lovr-integration.md) records the fork constraints. Keep patches narrow and additive, except for the documented internal OpenVR backend. Rebase the LÖVR patch branch onto upstream `dev` rather than merging it.

A fork change requires a commit pushed to the fork and a pointer update here in the same change. An unpushed pointer breaks other clones. Keep recorded submodule URLs HTTPS for anonymous access; a contributor's push remote may use SSH. Preserve upstream remotes for rebases. [.gitmodules](.gitmodules) owns fork URLs and branches.

## Lua conventions

These conventions apply to the Lua tree under `lua/`, the example configurations, and the development configuration under `dev/`. There is no upstream Lua template.

- Target Luau, which accepts Lua 5.1 syntax and adds type annotations. Do not use LuaJIT-only or Lua 5.2+ syntax that Luau rejects. Luau has no `goto`.
- Name every Lua source `.luau`, including a configuration's `main.luau` and `conf.luau`. The extension tells an editor that the source is Luau.
- Write a contract's data properties as `read`. Luau compares a read-write property invariantly, so `pose: Mat4` does not satisfy `pose: Mat4?`, and a type without the field does not satisfy an optional one. A read-only property is compared covariantly, and both do. `interaction.Surface` is the worked example.
- Name the contract type as a method's receiver in both the service declaration and the implementation. A receiver is a parameter, and parameters are contravariant, so an implementation that names its own type there cannot satisfy the contract. `any` on both sides typechecks and checks nothing.
- Put shared vocabulary in a neutral module when importing either service implementation would create a dependency cycle or unnecessary coupling. `lua/lunette-contracts/vocabulary.luau` is one.
- Model a closed set as a union, and discriminate it where its members differ. A field that tells the members apart narrows the rest: testing `panel.kind` reaches the `lunette.Window` behind a window panel.
- Fix a wrong declaration in the metadata or the generator, never in the calling code. Every workaround for a declaration that misdescribes LÖVR has changed behaviour: returning `true` from `lovr.quit` to satisfy its declared return vetoed the quit, and spelling an identity matrix as sixteen numbers followed from an ambiguous constructor.
- Use camelCase for functions and fields, matching LÖVR. Users write LÖVR code, and a second convention in the same file adds friction with no benefit.
- Use native `vector` values for three-dimensional positions, directions, and offsets. Construct them with `vector.pack`, keep `vector` fields in Config and Settings, and validate them with `schema.vector()`, which requires finite components. Vectors are immutable, so the caller keeps the value that a method such as `normalize` returns. Pass vectors to `Mat4:translate` directly, or unpack them at a scalar API boundary. Colours, two-dimensional coordinates, numeric lists, and full pose matrices keep their own representations.
- The standard plugins use only the public `lunette` API. A missing capability is a defect in the API, not grounds for a private path.
- Keep module responsibilities distinct. `lunette` is native mechanism, and policy is Lua, written as providers and consumers. Do not add policy to the native API or expect native mechanism from a provider. The plugin facade, contracts, plugins, and shipped desktop have separate roots, and the desktop root only composes plugins.
- A shipped plugin lives in `lunette-plugins` whatever its role: a provider under the contract it provides, and any other plugin under its entry id. `desktop/pacing` is `@lunette-plugins/pacing/controller`, and `desktop/persistence`, which provides `lunette/arrangement`, is `@lunette-plugins/layout/persistence`.
- A helper lives beside what it describes, in a contract's vocabulary or a provider's pure module, not in a root of helpers.
- Development-only plugins live under `dev/plugins/`, and `dev/main.luau` inserts them through relative requires. They are checked and tested but not installed, and they add no shipped desktop settings or runtime aliases. `make run` selects the development configuration and the source module roots from the repository root.
- The lunette API is available only in the main Lua state. Do not use it from `lovr.thread` or `lovr.task` states.
- Keep a plugin's optional `Config` separate from the resolved `Settings` its implementation receives. Use `plugin.provider` or `plugin.consumer` for configured definitions, and read services explicitly through `context:require`.
- Every module is safe to `require` twice. During source reload the host keeps the Lua state, shuts down the plugin runtimes, clears subscriptions and user modules, starts a new plugin contract epoch, and runs each cleared module's body again when the new configuration requires it. A module therefore keeps no module-level state that a second run would duplicate.
- Resources a plugin acquires are effects of its context or of its caller's owner, and the plugin runtime releases them. There is no teardown registry: the host does not clean up native resources a module holds outside a plugin.
- Register a resource on a caller's owner with `context:acquire(owner, acquire)`, and use `context:resource(owner, acquire)` when the acquisition returns a value as well as an effect. `acquire` returns the value and its inverse together, and releases its partial resources if it raises before returning. The helper returns only after native registration succeeds, and it does not replace context-owned cleanup.
- Never assume a handle survives a frame. Check `handle.dead` before use.
- Never cache the result of `window:getTexture()` across frames, because textures rotate as the client cycles its buffers. Use `window:stabilize()` when a persistent texture is needed.
- Raise errors normally, and do not swallow them to keep a frame alive. Event listeners and plugin callbacks run under a protected call, the frame provider protects each update, draw, key, text, and quit handler, and the boundary reports what they raise. A LÖVR callback assigned outside such a dispatcher is not protected; [Errors](docs/development/native/lua-api.md#errors) states the boundaries.
- The file-size threshold is around 500 lines, lower than the Rust threshold because Lua modules carry less ceremony.
- Comments end with a period. Headings and titles use sentence case.

### Formatting

`stylua.toml` configures StyLua, and `stylua --check lua etc/xdg/lunette examples dev crates/lunette/tests/luau_check crates/lunette/tests/graphics/fixtures` is a standing check. The settings record the style the tree already used: two-space indent, single quotes, no parentheses around a call's single string or table argument, and a 120-column width. `syntax = "Luau"` is set because the Lua grammars reject type annotations.

`.styluaignore` exempts the generated `lua/lunette/init.luau`, because the generator writes one declaration per line and does not reproduce StyLua's line breaking.

### The Luau static check

`make check-luau` runs the Luau checker against the generated definitions over `lua/lunette`, `lua/lunette-plugin`, `lua/lunette-contracts`, `lua/lunette-plugins`, `lua/lunette-desktop`, the shipped configuration, the configurations under `examples/`, and the development configuration and plugins under `dev/`. It skips every `tests` directory and `lua/testing`. The user-facing `lunette check` command uses the same checker. Session startup does not run the checker.

The checker runs in strict mode. `etc/lunette/definitions.luau` declares the LÖVR runtime. `crates/lunette-generate-definitions` generates it from lovr-docs, so a missing `lovr` field is fixed in the metadata or the generator, not by editing the output. Luau declares the standard functions itself, and the runtime has no `io`, so neither is declared there. Lua modules carry their own service and configuration types. The checker checks those shapes but does not prove that a plugin graph is wired correctly; the plugin runtime validates declarations and providers.

Test files and `lua/testing` are not checked. A test builds the windows, seats, and sources it needs as the smallest table each case requires, and the fake native API installs functions onto the `@lunette` table, while the handle types are exact. Checking tests would mean building a whole handle per case or casting each one, and both make the tests worse. A case that needs a real shape gets it from the module under test.

The check catches the two defect classes static analysis exists for: a local referenced before its declaration (`Unknown global`), and an accidental global (`GlobalUsedAsLocal`).

### Lua tests

A module's tests live in a `tests` directory beside it, never among its sources: `lua/lunette-plugins/pacing/service/tests/pacer.luau` covers `lua/lunette-plugins/pacing/service/private/pacer.luau`. Every `.luau` file directly inside a `tests` directory is a test file. Helpers shared by test files go in `tests/support/` and are required relatively, as `require './support/fixture'`. Any other file under a `tests` directory fails discovery, so a test file placed one directory too deep is reported rather than silently skipped. Scaffolding used by tests in more than one place goes in `lua/testing`, the development-only `@testing` root, and nowhere else.

A test file returns a suite of named cases:

```luau
local testing = require '@testing'
local expect = testing.expect
local test = testing.suite()

test('a case named as a sentence', function()
  expect.equal(1 + 1, 2, 'the sum')
end)

return test
```

`crates/lunette/tests/lua/` runs the Lua integration suites under `lua/` and `dev/`. [Build and development](docs/development/build-and-development.md#lua-tests) describes the runner. Neither the tests nor `lua/testing` are installed.

### The module roots

The root aliases and source directories are inventoried in `crates/lunette/src/aliases.rs`; [Build and development](docs/development/build-and-development.md#module-roots) explains runtime resolution and installation. File-backed aliases resolve through LÖVR's virtual filesystem in a session and through `.luaurc` files in the checker and editor. `@lunette` is registered through `package.preload`.

A relative require, `./`, `../`, or `@self`, resolves against the requiring file by Luau's require-by-string rules, in the checker and in a session alike. `crates/lunette/src/require` wraps the session's `require` so that LÖVR's loader, which knows only the root of its virtual filesystem, agrees with the checker. [Module roots](docs/development/build-and-development.md#module-roots) states the rules.

`crates/lunette/src/aliases.rs` describes the roots and their runtime resolution. The generator derives the `.luaurc` files from those descriptors, and `make check-definitions` verifies them. The Rust install manifest names the installed roots and generated declarations, and `make install` consumes it. `lunette --dump-config` writes a `.luaurc` beside the copied configuration that names the installation's Lua root by absolute path. A configuration is copied with that command, not by hand, because a `.luaurc` in the tree resolves its aliases relative to itself: a copy beside a user's configuration names a directory that does not exist, and every `require` fails to resolve, in `lunette check` and in the editor.

## General conventions

### Correctness over convenience

- Model the full error space, with no shortcuts or simplified error handling.
- Handle all edge cases, including race conditions, signal timing, and platform differences.
- Encode correctness constraints in the type system: newtypes, builder patterns, type states, and lifetimes. Never use a bare string or integer where the domain gives it a meaning; a recognised closed set of values is an enum, not bare strings.
- Prefer compile-time guarantees over runtime checks where possible.
- Use message passing or the actor model to avoid data races in concurrent code.
- Never silently drop content that cannot be represented. When adapting data between formats, return an error for anything the target cannot express. The caller may choose to ignore it; silent data loss is a correctness bug.
- Validate at each layer the data crosses, not only where a bug happened to surface. The next code path, refactor, or test double bypasses a single check. The goal is to make the bad state structurally impossible, not locally absent.
- Get the details right.

### User experience as a primary driver

- Every session UI renders in VR space, and every action is reachable through VR controls, including opening and closing panels, navigation, search, configuration, and text entry. Projected flat panels are valid VR UI. No session workflow requires a flatscreen interface, a physical keyboard, or a mouse, and the VR path stays complete without keyboard or mouse bindings. Developer command-line tools and logic-headless test runners are outside this requirement.
- Provide structured, helpful error messages that a later stage can render with an appropriate library.
- Make progress reporting responsive and informative.
- Keep behaviour consistent across platforms even when the underlying OS capabilities differ. Use OS-native logic rather than emulating Unix on Windows or the reverse.
- Write user-facing messages in clear present tense: "Frobnicator now supports..." not "Frobnicator now supported...".

### Pragmatic incrementalism

- Prefer specific, composable logic over abstract frameworks.
- Evolve the design incrementally rather than attempting a perfect upfront architecture.
- Apply the rule of three: do not abstract a pattern before it appears three times. Three similar lines beat a premature abstraction, which is harder to remove than it was to add.
- Do not build for hypothetical future requirements.

### Dependencies

- Reaching for a dependency for something trivial and handrolling something with a long correctness tail are both mistakes, and the second is the more expensive.
- Handroll code that is small and self-contained, where the whole problem is visible: a builder, a wrapper, a couple of pure functions.
- Take the dependency when the problem has a tail that would otherwise surface in production: dates and timezones, Unicode, text encodings, compression, TLS, and anything cryptographic. Never handroll cryptography.
- Prefer an existing dependency, including one of its feature flags, over a new one, and a focused library over a framework of which 5% would be used.
- Where the project documents a chosen stack, use it rather than silently introducing an alternative.
- When the choice is unclear, ask rather than picking silently. Either direction is cheap to change early and costly to change late.

### Boundaries and compatibility

- A library never reads environment variables. Configuration, such as keys, URLs, feature flags, and paths, arrives as parameters, and only the application entry point reads the environment. Otherwise the library cannot be tested without changing the environment, and it is silently coupled to a deployment.
- When changing anything serialised to disk or sent over a wire, walk the whole version matrix: old reader with new data, new reader with old data, and old writer with new data.
  - The third case is the one that gets missed. A default lets an old reader parse new data, but an old writer then drops the fields it does not know on write-back, which corrupts the file instead of failing.
  - Bump the format version when the field is added, not when code first depends on it.

### Functional core, imperative shell

- Keep decision logic in pure functions that take data and return data. Keep I/O, concurrency primitives, and orchestration in a thin shell at the edges.
- The shape is gather, process, persist: the shell collects the inputs, the core decides, and the shell writes the result. A core function that reads something mid-decision is what this rule prevents.
- Isolate coupling to the outside world, such as the filesystem, clock, network, subprocesses, and devices, behind a small seam: a trait, an interface, or a dependency struct, with a production implementation and a test fake. Tests are deterministic because they substitute the fake, not because they clean up after the real thing.
- The payoff is testability. A pure core needs no fakes, and a thin shell has little logic worth mocking. A test that needs elaborate setup to reach the behaviour it checks usually points at the shape of the code.

### Code organisation

The language sections set the file-size threshold and naming conventions. These rules apply everywhere.

- Name a file for what it holds, not for a category. No `utils`, `helpers`, `common`, or `misc`: such files become dumping grounds, because a name that claims nothing excludes nothing. A file named for string formatting, date arithmetic, or API error handling is hard to put the wrong thing in. The language sections give the casing.
- Within a file, put the public API first and the private implementation below it: constants, helpers, and internal types. Order the private items by use, roughly in the order the public API reaches for them.
- Split a file along natural seams, such as distinct data types, feature groups, or functional areas, not arbitrarily at the line limit. A cohesive single-concern file slightly over the threshold beats a fragmented one.
- Group a wide folder into subfolders by domain or role. A flat folder of 20 or more files calls for subfolders.
- Test files follow the same thresholds as the code they test.

### Testing

- Test comprehensively, including edge cases, race conditions, and stress tests.
- Reuse the existing test facilities.
- When fixing a bug, add the failing regression test first, then make it pass.
- Use real instances of what the project controls, and fakes for what it does not. The project's own database or filesystem is a managed dependency: talking to it is an implementation detail that can be refactored freely, so tests use the real thing. A third-party API, an SMTP server, or a message bus is unmanaged: that conversation is observable behaviour, so it goes behind a fake.
- Do not mock what the project does not own. Wrap the third-party library in a thin interface of the project's own and substitute that, rather than mocking the library's surface. The test is simpler and the design better.
- Never add a method to production code that only tests call. Cleanup and inspection helpers belong in test utilities.
- Wait for conditions, not durations. Poll for the expected state with a timeout instead of sleeping long enough that it is probably ready, which passes locally and fails in CI. A fixed sleep is right only when the behaviour under test is about timing, such as a debounce, and then a comment explains the duration.
- Clean up long-lived resources: containers, VMs, processes, and cloud objects. Do not scrub database rows and log entries; perfect data cleanup makes multi-step integration tests nearly impossible. A test that needs pristine state mints unique identifiers instead of depending on an empty table.
- Do not write a test that only exercises serialisation or a derived implementation. A round-trip test earns its place only when it guards a real wire: a versioned payload, a public API, or a file format.
- No personal names in fixtures, and never the author's own identity. Anonymise every test and fixture to invented placeholders. Do not seed one from a real person's name, handles, or biographical details, even when real data reproduces the behaviour under test. Reproduce the shape of what was observed, never its content.

Where a function has a property worth stating, prefer a property-based test to a handful of examples. Use the strongest property that applies. In increasing order of strength: does not crash, preserves the type, holds an invariant, is idempotent (`f(f(x)) == f(x)`), and round-trips (`decode(encode(x)) == x`). An oracle property, where a new implementation must agree with the old one, is the tool for a rewrite.

A property test can look sound and test nothing in two ways. It can be tautological, comparing an expression with itself. Or it can restate the function's logic in the assertion, so that a reasoning error appears in both halves and cancels out. Include the degenerate cases, such as empty and single-element inputs, explicitly rather than trusting the generator to find them.

### Documentation

- Use inline comments to explain why, not only what.
- Do not add narrative comments in function bodies. Comment only code that is non-obvious or special, or that needs a deeper explanation of why.
- Module-level documentation explains the module's purpose and responsibilities.
- Comments and documents describe the present state. Reserve past-tense narration for the rare case where history explains a standing reason.
- Keep the user-facing docs in sync with the code. Where a document restates something the code owns, such as a configuration default, an example configuration, a generated reference, or an API surface, name the code as the source of truth and update the document in the same change. A code change without its documentation update is not finished.
- Where possible, generate the document from the code and check it in CI rather than relying on memory.
- End code comments with a period.
- Use sentence case for headings and titles, never title case.
- Use the Oxford comma.
- Keep articles ("a", "an", "the"). Write "the file has a newer version", not "file has newer version".

The two sections that follow are the Rust template. They apply to Rust code in this repository, and the Lua conventions above apply to Lua.

## Code style

### Rust edition and linting

- Use the Rust 2024 edition.
- Format with nightly rustfmt: `cargo +nightly fmt --all`. `rustfmt.toml` sets `imports_granularity = "Crate"` and `group_imports = "StdExternalCrate"`, which are nightly-only. Stable rustfmt warns about each and then skips them, so a file formatted with stable rustfmt differs from one formatted with nightly.
- Make the checks pass at the end of each complete task; intermediate steps need not pass. `make check` runs all of them, and `.github/workflows/ci.yml` calls the same targets, so a check added to the Makefile is added to both. The Makefile holds the commands. The targets are:
  - `make check-format`: nightly rustfmt, and StyLua over the Luau (see [formatting](#formatting)).
  - `make check-headset`: hardware-free native headset tests through CMake and CTest, including harness failure propagation and missing-runtime cleanup. It builds the shader compiler from the vendored `deps/glslang`.
  - `make check-graphics`: offscreen shader and pixel-readback tests through real LÖVR, with an explicitly selected Mesa lavapipe Vulkan ICD. It opens no window and loads no headset, audio, filesystem, or compositor. [Build and development](docs/development/build-and-development.md#offscreen-graphics-tests) records the software-driver prerequisites.
  - `make check-install`: hardware-free installation tests using real ELF fixtures, fake Cargo, and the Makefile installation rules. It requires Python, a C compiler, and patchelf.
  - `make check-rust`, which is `make check-clippy` and `make check-test`, each over both feature sets. CI runs the two as separate parallel jobs, because clippy builds through `RUSTC_WORKSPACE_WRAPPER` and shares no artifacts with a normal build; in series the workspace would be compiled twice.
  - `make check-definitions`: regenerates every generated artifact in memory and fails if any differs from the checked-in copy, naming the first differing line. Run `cargo run -p lunette-generate-definitions` and commit the result. It covers `etc/lunette/definitions.luau`, `lua/lunette/init.luau`, and the `.luaurc` files (see [the module roots](#the-module-roots)).
  - `make check-luau`: the Luau type checker over the shipped Lua roots outside their `tests` directories, the shipped and development configurations, and the examples (see [the static check](#the-luau-static-check)).
- Configure clippy's restriction lints in `[workspace.lints.clippy]` in the workspace root's `Cargo.toml`, and opt each crate in with `[lints] workspace = true`:

  ```toml
  [workspace.lints.clippy]
  unwrap_used = "warn"
  expect_used = "warn"
  ```

- The end-of-task and CI clippy commands pass `-- -D warnings`, so any warning fails them. A plain `cargo clippy` run reports warnings without failing.
- Use `cargo clippy` in place of `cargo build`. It typechecks and lints in one pass, so a separate build adds nothing.
- Iterate in debug. Use `--release` only for benchmarking or packaging.
- No `unwrap()` or `expect()` in production code; tests may use them. The restriction lints are at `warn`, and `-D warnings` makes every warning an error, including inside `#[cfg(test)]`. A test module whose cases use `expect` therefore carries `#[expect(clippy::expect_used, reason = "...")]`, naming the lints it actually uses, with a reason stating the rule. The vendored `lunette-compositor` crate does not opt in with `[lints] workspace = true`: it carries WayVR's code, whose tests use `expect` freely, and it is exempt from house style until rewritten.
- Never silence a lint without a concrete reason in a comment above it. Restructuring the code is almost always the right fix.
- When suppressing a lint, use `#[expect(...)]` rather than `#[allow(...)]`. `expect` warns when the suppression becomes unnecessary, so stale suppressions cannot accumulate.

### Type system patterns

- Builder patterns for complex construction, such as `TestRunnerBuilder`.
- Type states encoded in generics when state transitions matter.
- Lifetimes used extensively to avoid cloning, such as `TestInstance<'a>`.
- Newtypes for domain types, following the general rule against bare primitives.
- `#[non_exhaustive]` on public types in a library crate with a stable API, so a new variant or field is not a breaking change. Internal crates do not need it.
- Parameter structs instead of long argument lists. When a function approaches the `clippy::too_many_arguments` threshold, bundle the cohesive parameters into a struct: a request struct, or a shared seam such as `Engine { store, graph, clock }` that several call shapes pass along.
  - Never silence that lint with an `allow`; the lint firing means a struct is wanted. The one exception is a signature the project does not own, such as an FFI shim or a hook mirroring a foreign ABI, where the `allow` is the honest annotation.

### Error handling

- Do not use `thiserror`. Implement `std::fmt::Display` and `std::error::Error` by hand for each error `struct` or `enum`. `Error::source` returns the wrapped cause where there is one, so the chain stays walkable.
- Group errors by category with an `ErrorKind` enum where appropriate.
- Provide rich error context through structured error types.
- Use a two-tier error model:
  - `ExpectedError`: user and external errors, with semantic exit codes.
  - Internal errors: programming errors, which may panic or use internal error types.
- Every error's `Display` starts with a `<context>:` prefix naming the subsystem or operation, followed by the cause: `event store: …`, `lua: block commit failed: …`, `could not open the event log at /path: …`. Messages stay lowercase so they compose.
  - An aggregating error prefixes its own layer's context and delegates to the inner error, so a chain reads as nested context: `turn: lua: block commit failed: event store: …`.
  - Add resource context, such as a path or an id, at the layer that has it. Avoid bare "failed to {x}" glue; name the operation.

### Async patterns

- Do not introduce async to a project without async.
- Use `tokio`, multi-threaded, as the async runtime.
- Use async for I/O and concurrency, and keep other code synchronous.
- Use `parking_lot::Mutex` for synchronous locks by default. Its guard does not poison and must never be held across an `.await`. Reserve `tokio::sync::Mutex` for the rare guard that must survive an `.await`; most locks are acquired, used, and dropped within a synchronous span.
- Use bounded `mpsc` channels. An unbounded channel hides backpressure.

### Logging

- Use `tracing` for diagnostic and operational logging, emitting at meaningful points rather than noisily.
- Install the subscriber only in binaries, and send logs to stderr.
- Operator and diagnostic programs also route their output through `tracing`. Reserve stdout and `println!` for machine-readable command output.

### Module organisation

- Use `mod.rs` files to re-export public items. Nontrivial logic lives in submodules, not in `mod.rs`.
- Keep module boundaries strict with restricted visibility. Prefer `pub(crate)` and `pub(super)` to `pub(in <path>)`, which is precise but reads as a smell; use it only when neither of the others expresses the scope.
- Use `#[cfg(unix)]` and `#[cfg(windows)]` for conditional compilation.
- Import types and functions at the top of the module. The one exception is a `cfg()`-gated function. Never import types or modules inside a function.
- Importing enum variants for pattern matching is fine.
- Re-exports follow the same rule: a `pub use` belongs at the top of the module with the imports, not beside the item it re-exports. In a `mod.rs`, the `mod` declarations come first, then the `pub use` block, so the public surface reads as one list.
- A path used more than once in a module is imported at the top, as the specific items rather than the module, instead of being repeated in full at each call site.
  - A path used once may stay fully qualified, unless it is more than three module segments deep, in which case it is imported.
  - When the module already imports a sibling from the same parent, import the new item beside it rather than writing it inline.
- Anchor intra-crate paths at `crate::`, never `super::`. Write `crate::graph::Graph`, not `super::Graph` or `super::super::Graph`. The exception is a test module, where `use super::*;` is the idiomatic way to pull in the parent.
- Use one grouped `use` statement per crate root, collapsing shared prefixes: `use axum::{extract::State, http::StatusCode, routing::get};`, not three separate lines. Group imports into three blocks separated by blank lines: `std`, external crates, then `crate`, `super`, and `self`. `imports_granularity = "Crate"` and `group_imports = "StdExternalCrate"` in `rustfmt.toml` enforce both under nightly rustfmt.

### Code organisation

The general code-organisation rules apply. These are the Rust specifics.

- The file hierarchy is the architecture diagram. A newcomer reading the directory listing can infer what the project does.
  - A subsystem with a public entry point is a folder module whose `mod.rs` states the boundary, with private submodules inside. Only `lib.rs`, `main.rs`, and cross-cutting types such as `errors.rs` stay as top-level single files.
  - Avoid a top-level single file where a folder grouping is natural. If several files are semantically related, or file A is used only by file B, merge them.
- The file-size threshold is around 1000 lines. Past it, split the file into a folder and re-export the public items from `mod.rs`, so consumers see a stable API.
  - Methods on one type can spread across several `impl` blocks in different files of the same module, so splitting needs no visibility or trait plumbing.
  - A large inline `#[cfg(test)] mod tests` counts toward the total. Moving it to a sibling `tests.rs` is often the whole fix.
  - Existing oversized files are grandfathered. Split one when a change touches it substantially, not as drive-by churn.
- Shared helpers for a split test module live in its `mod.rs`.

### Control flow and state machines

- Avoid rightward drift. When a function nests three `select!` blocks or four levels of `match` or `if let`, extract each arm into a named function that takes a context struct, so the top level reads like an outline.
- Model each state machine as an explicit `enum` with named variants, even when only one field differs between them. Prefer an exhaustive `match` with a `transition` helper to scattered `if let` chains.
- Where a subsystem passes through phases that own different local state, such as `Idle`, `Starting`, `Running`, and `Draining`, extract each phase body into its own function that takes a typed context struct. This is the pragmatic form of the typestate pattern for actor-style loops; it keeps invariants local without fully type-parameterised phases.
- Make invalid transitions unrepresentable at the boundary where they are consumed. If `transition()` returns `Option<State>`, production code never `.unwrap()`s it: either enumerate the legal inputs ahead of time or make the caller total.

### Platform coupling

- A file that depends on platform-specific facilities says so on the first line of its module docstring: `//! Linux-only: reads /proc/{pid}/cmdline.` A port to a second platform, or a reviewer, then knows the contract.
- Outside-world seams are traits, such as `Fs`, `ProcessSpawner`, `GpuProbe`, and `Clock`, bundled into one dependency struct that production and tests construct differently. A second OS implementation then follows the shape the fakes already required.
- When a second platform lands, gate the existing implementation with `#[cfg(target_os = "…")]` and add the alternative under a sibling gate. The trait definition stays platform-neutral.

### Reaching through smart pointers

- To borrow the value inside a lock guard, a `Box`, or an `Arc`, use `.as_ref()` or `.as_mut()` rather than a manual double dereference: `state.lock().as_ref()`, not `&**state.lock()`. The named form reads as borrowing the value rather than as dereference bookkeeping. The same applies to an `Arc<dyn Trait>`: `model.as_ref()`, not `&**model`.

### Serde

- Use `#[serde(deny_unknown_fields)]` on configuration types, and `#[serde(default)]` on new fields so they stay backwards-compatible.
- Use `serde_ignored` when deserialising configuration, so a misspelt or stale field is reported rather than ignored.
- Avoid `#[serde(untagged)]` when deserialising, because its error messages are useless. Write a custom visitor instead.
- Reserve `#[serde(flatten)]` for its real use: extending a shared struct with local fields, or a `toml::Table` catch-all that preserves unknown fields across a round-trip. It interacts badly with `serde_ignored` and with `deny_unknown_fields`.

### Memory and performance

- Decide deliberately when to clone and when to borrow. Share immutable data behind `Arc` or `Rc`, or borrow it. Where data has a natural tree or graph shape, share the nodes rather than cloning subtrees.
- Use `smol_str` for small strings.
- Use `smallvec` for collections that are usually small, to avoid heap allocation in the common case.
- Stream data, for example with iterators, rather than buffering it where possible.

### Dependency versions

- Pin exactly in applications, binaries, and workspace-internal crates. Cargo's default caret range lets resolution drift between `cargo update` runs, and `serde = "=1.0.219"` makes a bump a reviewable change.
- Use the narrowest working range in crates published to a registry. An exact pin in a published library breaks diamond-dependency unification: if two of a consumer's dependencies pin different patch versions of one crate, the consumer gets two copies or a resolution failure. Publish a range and let the consumer's lockfile pin.
- Manage shared versions in the workspace root's `[workspace.dependencies]` and reference them with `{ workspace = true }`.
- Check the current version of a crate before adding or bumping it, rather than writing one from memory.
- Comment on a non-obvious dependency choice, including a feature flag chosen for a reason.

## Testing

### Testing tools

- test-case, for parameterised tests.
- proptest, for property-based tests.
- insta, for snapshot tests.
- libtest-mimic, for custom test harnesses.
- pretty_assertions, for readable assertion output.
- Use `cargo nextest run` in place of `cargo test` where it is available.

### Testing conventions

- Unit tests live in the same file as the code under test, in a `#[cfg(test)] mod tests` block. Integration tests live under `tests/`.
- Never `#[ignore]` a test, and never let one skip silently. A test that cannot run in an environment is gated by a `cfg` or a feature, so its absence is visible.
- Tests are deterministic: no real subprocesses, no real filesystem, no wall-clock sleeps, and no network. Route each through the seam traits above and substitute the fake. Gate a fake behind `#[cfg(any(test, feature = "test-fakes"))]` when integration tests need it too.
- A compositor test connects its client over an in-process `UnixStream::pair()`, with `Connection::from_socket` on the client side and `DisplayHandle::insert_client` on the compositor side, which binds nothing and touches no filesystem. A test waits for conditions when it waits for a client to map a surface.
- The exit-status test is a narrow exception to the subprocess part of the same rule. `crates/lunette/tests/exit_status.rs` spawns the real binary against checked-in fixture configuration directories under `crates/lunette/tests/fixtures/` and asserts the process's exit status. The status is a property of the process, not a value a function returns: `boot::run` yields an opaque `ExitCode`, and the code that produces it needs a live LÖVR Lua thread, so the test has no in-process form. The exception covers the exit status only. The fixtures disable the audio, graphics, and headset modules and open no window, so the run needs no display, XR runtime, or sound device, and it neither sleeps nor uses the network. It does write LÖVR's save directory, which `lovr.filesystem.setIdentity` always creates. Each run points `XDG_DATA_HOME` at its own temporary directory and each fixture has a distinct identity, so the write lands inside that directory, two parallel runs cannot race to create one shared leaf, and the result does not depend on `HOME` or on the running uid having a passwd entry.
- Installation tests are a narrow exception to the subprocess and filesystem rules. `crates/lunette/tests/fixtures/install.py` runs the actual Makefile with fake Cargo and real ELF fixtures in isolated temporary directories under `target/`. Installation paths, permissions, and dynamic-library resolution are the behaviour under test, so replacing those operations would remove the oracle. These tests use no headset, graphics hardware, runtime, network, or wall-clock sleeps.
- Never call `Connection::connect_to_env()` in a test. It calls `env::remove_var("WAYLAND_SOCKET")`, which mutates the process environment and is unsound in a multithreaded test binary. Tests use only `Connection::from_socket`.
- Time is a narrow exception when everything already runs on `tokio::time`: `#[tokio::test(start_paused = true)]` with `tokio::time::advance` gives virtual time without another seam.
- Control-socket and offscreen graphics tests may also use isolated subprocesses or files; they require no live display, XR runtime, or network.
