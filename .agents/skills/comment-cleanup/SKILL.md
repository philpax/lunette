---
name: comment-cleanup
description: Clean up comments in maintained source files while preserving boundary-critical contracts and rationale.
---

# Comment cleanup

Use this skill when reducing comments in maintained source files.

## Scope

Read the whole file before editing comments. Include Rust, Luau, Lua, Luau definitions, manifests, build files, and configuration files when they are in scope. Exclude submodules and generated files unless the task explicitly includes them. Fix generated comments in their metadata or generator source, not in the generated output. Existing documents are out of scope unless the task changes their specification; update normative documents when behavior or public contracts change. Vendored files retain their upstream style unless a substantial rewrite includes them.

Change comments only. Do not change executable code, formatting unrelated to comments, or generated output.

## Decide whether a comment stays

Keep a comment only when it gives information that a reader cannot get from the nearby code and that matters to the consumer or maintainer. Comments explain why, not what. Function-body comments are limited to non-obvious behavior or deeper rationale. Valid reasons include:

- a public API contract;
- a safety, FFI, ABI, or ownership constraint;
- a lifecycle, ordering, persistence, compatibility, or protocol invariant;
- a test seam or regression condition;
- a non-obvious build, linker, platform, or dependency constraint;
- a short reference to the authoritative document when the document contains the detail.

Delete comments that:

- repeat the item name or the next statement;
- explain an obvious branch, assignment, or data structure;
- describe callers, callers that do not exist, or a particular current call path;
- refer to a task, phase, acceptance criterion, pilot, internal ticket, or other temporary work;
- cite internal requirement identifiers such as `lunette-v1.AC4.3`;
- describe a past implementation state;
- duplicate a document or another nearby comment;
- use source line numbers, character positions, or other fragile locations.

Apply theory of mind. Ask whether the comment helps the external user or the maintainer at this boundary. Remove implementation details from public API comments when they do not affect the contract.

## Rewrite rules

Use plain technical prose. State one fact per sentence in present tense. Use active voice and simple terms. Name the actor instead of personifying software. Use one term consistently for each concept. End comments with periods. Use sentence case for headings and titles, the Oxford comma, and the required articles. Avoid metaphors, idioms, allusions, rhetorical questions, and language about what the code wants or knows.

State mechanism, not verdicts. A comment that reassures the reader ("a prompt is normal", "this state is expected", "that is acceptable") argues instead of specifying; write what happens and under what condition, and the reader derives the rest. Do not use persuasive connectives such as "therefore" to stage a conclusion the sentences have not earned. A vague abstraction such as "carries plain data" names no mechanism; name what the data is and what each side does with it.

Write headings as noun phrases naming their subject: "Restore behaviour", "Thread affinity", "Logical coordinates". A heading that asserts a claim or offers reassurance is prose misplaced in a title.

Keep item documentation short. Prefer one or two sentences. Describe the public contract and its externally relevant constraints, not the implementation. Keep the rationale when it explains a safety, FFI, ABI, ownership, lifecycle, ordering, persistence, compatibility, protocol, platform, build, or test invariant. Delete implementation history, caller-specific explanations, task language, and obvious narration. Treat deletion as the default for redundant module and method prose, not for method documentation as a category. Preserve a concise method contract when the method crosses a protocol, thread, ownership, error, host/client, or other external boundary. Delete a method comment only when its signature, name, types, and surrounding code fully expose its contract. For every retained comment, identify the specific fact it adds. Delete comments that only restate the method's operation, a field's type, the module layout, or normal library behavior. Compare the documented API surface before and after the pass and flag unexplained documentation loss. Preserve provenance and license information when the repository requires it, but state whether the file is derived from, adapted from, or copied from the named source. Do not imply that the whole file came from an upstream source when only part of it did. Never include a line number, character range, or other fragile source location.

Keep inline comments shorter than item documentation. Explain why the code is non-obvious. Do not narrate the next statement. A platform-dependent Rust file starts with a module comment naming the platform and facility it uses. Preserve required copyright and license notices.

Wrap prose at the Rust house-style limit of 100 columns. Wrap between sentences or at clause boundaries, never inside a sentence at an arbitrary point, and never capitalize a word to justify a line break. A wrapped line continues the same sentence; a period appears only where a sentence ends. Use headings only for distinct subjects, and name the subject rather than the reader's experience. Remove emphasis formatting from comments unless the formatting is part of a real structural element such as a code span or link.

Rewrite means rewrite: restate each comment's content in the target register rather than swapping individual words. Changing "Ported" to "Adapted" or "a caller" to "the caller" while leaving dense or rhetorical prose intact does not meet this standard. Conversely, condensing must preserve every distinct fact: if the original gives a reason, the rewrite states that reason.

## Review

Read the whole file before editing it. Review every comment in the file, not only comments found by a search. Check each changed comment against the surrounding code and the authoritative documents. Preserve every meaningful decision, caveat, number, cross-reference, and test condition. Check that deletion does not remove safety, compatibility, lifecycle, protocol, or test rationale. When an original comment gave diagnostic guidance (which outcomes are routine and which indicate a fault), keep that distinction.

Check comments at boundaries and state transitions for more than their local code. Preserve provenance, ownership, lifetime, thread-safety, protocol-version, ordering, and test-seam constraints. Remove comments that merely restate a field type, method name, return value, or nearby lint reason. Replace caller-specific narration with the invariant that applies to every caller. Remove implementation details that explain how a value is derived when the consumer only needs to know what the value represents. Preserve the reason a field or object must remain alive when dropping it changes the advertised protocol or resource lifetime. State partial provenance precisely: identify which files or fragments are adapted, rather than implying that the whole file comes from an upstream source. Remove fragile source locations unless they are required stable references. A clear rewrite is not a successful cleanup if the comment should have been deleted.

Use regex searches before and after editing to find fragile references and temporary identifiers. At minimum, search comments for line-number forms such as `:[0-9]+` and `:[0-9]+-[0-9]+`, path-plus-line references, internal requirement identifiers such as `[A-Za-z0-9_.-]+\.AC[0-9]+\.[0-9]+`, and task or phase names. Review every comment in the file, including comments that already appear plain. For each retained comment, make a case that it states a contract, rationale, or invariant that the nearby code does not make clear. Do not limit the pass to comments matched by a search or to comments changed by an earlier agent.

Use `git diff --check`. Confirm that the diff changes comments only. Read the rewritten comments as prose, start to finish: a rewrite that inserts a period at every wrapped line, capitalizes mid-sentence, or leaves sentences that no longer parse is defective regardless of what it removed. Run the repository's prescribed format and test checks after the batch is complete.

## Register verification

The register of `plain-technical-prose` is the binding standard for the prose this skill produces. A pass is not complete until the file's comments satisfy the register, not merely the deletion-and-content rules above. Beyond what the register states, the following defects have recurred in practice and must be treated as failures; scan every comment with regex before considering the pass done, and fix every match:

Banned phrase classes (grep for these, in comments only):

- em-dashes and en-dashes: `—`, `–`;
- verdict phrasing and formulaic contrast: `rather than`, `instead of`, `as opposed to`, `in lieu of`, `not X but Y`;
- intensifiers and minimizers: `correctly`, `properly`, `simply`, `just`, `merely`, `only`, `at all`, `of course`, `obviously`, `clearly`, `importantly`, `deliberately` when it no more than reassures;
- rhetorical and generated-sounding connectives: `which is what`, `what makes this`, `is what lets`, `so that`, `therefore` as a persuasive stage, `note that`, `in other words`, `as it were`, `it is worth`;
- puns, idioms, and metaphors: `as X requires` (when X is a function name), `splices in`, `threaded through`, `behind the scenes`, `under the hood`, `drives`, `sits`, `lives`, `speaks`, `wants`, `knows`, `thinks`, `claims`, `tells`, `asks` where the subject is a component rather than a person, `the one that`, `the honest`, `the real` when it is a verdict;
- past-tense and historical narration describing implementation history: `was`, `were`, `had` used to narrate what the code once did; `it was missed once`, `before`, `previously`, `used to`, `formerly`, `originally`, `since` (as history);
- self-reference and process language: `this comment`, `this file`, `this pass`, `as requested`, `per the review`, `the task`, `cleanup`, `rewrite`, `register`;
- fragile locations: line numbers, `path:line`, requirement identifiers (`[A-Za-z0-9_.-]+\.AC[0-9]+\.[0-9]+`);
- first and second person: `you`, `your`, `we`, `our`, `us`, `I`, `my`.

Do not let a match pass because it reads "fine" in context: each of these constructions has a plain-register replacement (split the sentence, name the actor, state the mechanism, drop the intensifier, present the fact). Exclusions: executable strings, identifiers, and test names are not comments and are untouched; a `SAFETY` or `# Safety` block mandated by a lint keeps its contract text but still must not contain these forms.

The check is against the file as it will be committed. This register verification is part of the task and of the adversarial second pass, not an optional polish.
