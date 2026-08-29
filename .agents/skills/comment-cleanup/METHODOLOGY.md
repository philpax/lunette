# Comment cleanup methodology

Use a double-dispatch pass for dense maintained files. The first agent performs a deletion-first rewrite. The second agent reviews the original file, the rewritten file, and the complete diff as an adversarial editor.

## First pass

1. Read the complete file before editing.
2. Review every comment, including module documentation and comments that already appear plain.
3. Search comments with regex for file-and-line references, path-and-line references, internal requirement identifiers, task names, phase names, and temporary identifiers.
4. Treat deletion as the default for redundant module and method prose, not for method documentation as a category.
5. Preserve a concise method contract when the method crosses a protocol, thread, ownership, error, host/client, or other external boundary.
6. Delete a method comment only when its signature, name, types, and surrounding code fully expose its contract. Compare the documented API surface before and after the pass and flag unexplained documentation loss.
7. Preserve only the specific facts that matter to the consumer or maintainer: protocol behavior, ownership, lifetime, thread affinity, ordering, compatibility, error handling, test seams, build constraints, and precise provenance.
7. Change comments only. Run `git diff --check` and the prescribed format check. Do not commit.

## Second pass

1. Read the original file from `HEAD`, the current complete file, and the complete diff.
2. Inspect every remaining comment, not only comments changed by the first pass.
3. Ask of each retained comment: what specific fact would a maintainer miss without it?
4. Delete comments that restate operations, types, module layout, normal library behavior, return values, or visible control flow.
5. Rewrite retained comments that remain rhetorical, caller-specific, historical, overly detailed, or generated-sounding.
6. Compare the documented API surface before and after the first pass. Restore or rewrite any missing method contract that crosses a protocol, thread, ownership, error, host/client, or other external boundary.
7. Re-run the regex searches and verify that the remaining matches are executable data or required provenance rather than fragile comment references.
8. Confirm that the diff changes comments only. Run `git diff --check` and the prescribed format check. Do not commit.

A rewrite is incomplete when it preserves an unnecessary comment in cleaner prose. A retained comment must earn its place by stating a non-obvious contract, rationale, or invariant.
