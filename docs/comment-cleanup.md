# Comment cleanup

## Classification

Classify each comment as a public contract, safety or FFI rationale, invariant or compatibility rationale, test rationale, example, provenance or history, documentation duplicate, or redundant narration.

Public contracts state behaviour that callers rely on. Safety and FFI comments state constraints at an unsafe or representation boundary. Invariant and compatibility comments state rules that are not visible from the local code. Test comments state why a fake, fixture, or regression case is necessary. Examples illustrate an interface. Provenance and history comments remain only when the history explains a current constraint. Documentation duplicates repeat information owned by a subject document or generated source. Redundant narration repeats names, types, control flow, assertions, or visible fixture setup.

## Rules

Delete redundant narration and temporal references to completed phases. Keep durable rationale that explains a non-obvious safety, lifecycle, Vulkan, persistence, compatibility, protocol, type, or test-seam constraint. Preserve doctests and public contracts.

Use present-tense, plain technical prose. Use short declarative sentences, active voice, one idea per sentence, and periods at the end. Do not use second-person language, metaphors, or comments that merely announce the next statement.

Review deletions separately from rewrites. A deleted comment is acceptable only when the adjacent code is self-explanatory or the information is duplicated by an authoritative source. A rewritten comment must retain the current constraint and its consequence.

## Exclusions

Generated files, vendored code, fork submodules, external dependencies, and existing subject documents are outside this pilot. The pilot does not move rationale into another existing document. It does not change executable code, formatting unrelated to comments, or generated output.

The ten lanes are:

| Lane | Files | Deleted narration | Retained rationale | Out-of-scope changes |
| --- | --- | --- | --- | --- |
| 1 | `lua/mullion/persist/init.lua` | Repeated module and declaration-order narration. | Soft and hard persistence, mirrored-monitor API limits, future or unreadable file refusal, and restart-stable keys. | None. |
| 2 | `lua/mullion/rules.lua` | Repeated declaration-order and phase narration. | Metatable, reload, source-precedence, and missing-tag constraints. | None. |
| 3 | `lua/spec/mullion/panel/panel_spec.lua` | Helper, rendering, and phase narration. | Shader cleanup, opaque alpha padding, matrix-copy behaviour, graphics-free shader seam, and square-layer viewport requirements. | None. |
| 4 | `lua/spec/mullion/panel/raycast_spec.lua`, `lua/spec/mullion/pose_spec.lua` | Fixture and arithmetic narration. | Raycast mapping, bounds, face direction, pose immutability, public re-export compatibility, exact encoding, and persistence drift prevention. | None. |
| 5 | `lua/spec/mullion/persist/format_spec.lua`, `lua/spec/mullion/persist/file_spec.lua` | Assertion and fixture narration. | Old-reader and new-file compatibility, round-trip behaviour, and the real-filesystem boundary. | None. |
| 6 | `crates/lunette-luau/src/closed_set.rs` | Repeated macro-example detail. | The macro contract, generated public names, and the doctest. | None. |
| 7 | `crates/lunette-capture/src/portal/correlation.rs` | Algorithm and test-case narration. | Portal backend limitations, logical-geometry fallback, order independence, connector precedence, scaled-output size mismatch, and ambiguity handling. | None. |
| 8 | `crates/lunette/src/texture/barrier.rs` | Historical and duplicated Vulkan commentary. | Runtime policy, acquire and release layouts, queue-family handling, FFI argument ordering, fallback warnings, and release-layout regression behaviour. | None. |
| 9 | `crates/lunette-generate-definitions/src/main.rs` | Generator orchestration and implementation narration. | Metadata as the source of truth, generated artifact paths, literal generator execution, and `--check` comparison behaviour. | None. |
| 10 | `crates/lunette/src/control/wire/tests.rs`, `crates/lunette/src/frame/tests.rs` | Protocol, fixture, and test-scaffolding narration. | Mixed-key representation, no-silent-loss and hostile-input bounds, stable version offsets, GPU-free seams, lifecycle idempotence, teardown ordering, and regressions. | None. |

## Generated files

Generated declarations and alias files remain unchanged. The generator remains the source of generated definitions. A generator change in this pilot is comment-only and does not alter generated output. `cargo run -p lunette-generate-definitions -- --check` verifies that checked-in artifacts remain current.

## Review

The final review asks whether every remaining comment explains information that is not obvious from nearby code. It checks safety, lifecycle, Vulkan, persistence, compatibility, protocol, and regression rationale after every deletion. It checks that each changed source hunk contains only comment or doc-comment changes. It checks that all prose describes the present state in a plain technical register.

The final path allowlist contains the ten lane paths and this file. No generated, vendored, forked, or existing documentation path may appear. `git diff --check`, the Rust and Luau checks, and `make check` provide automated validation; prose classification remains a manual review.
