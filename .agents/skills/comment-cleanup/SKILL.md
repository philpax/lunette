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
- refer to a task, phase, acceptance criterion, pilot, or other temporary work;
- describe a past implementation state;
- duplicate a document or another nearby comment;
- use source line numbers, character positions, or other fragile locations.

Apply theory of mind. Ask whether the comment helps the external user or the maintainer at this boundary. Remove implementation details from public API comments when they do not affect the contract.

## Rewrite rules

Use plain technical prose. State one fact per sentence in present tense. Use active voice and simple terms. Name the actor instead of personifying software. Use one term consistently for each concept. End comments with periods. Use sentence case for headings and titles, the Oxford comma, and the required articles. Avoid metaphors, idioms, allusions, rhetorical questions, and language about what the code wants or knows.

State mechanism, not verdicts. A comment that reassures the reader ("a prompt is normal", "this state is expected", "that is acceptable") argues instead of specifying; write what happens and under what condition, and the reader derives the rest. Do not use persuasive connectives such as "therefore" to stage a conclusion the sentences have not earned. A vague abstraction such as "carries plain data" names no mechanism; name what the data is and what each side does with it.

Write headings as noun phrases naming their subject: "Restore behaviour", "Thread affinity", "Logical coordinates". A heading that asserts a claim or offers reassurance is prose misplaced in a title.

Keep item documentation short. Prefer one or two sentences. Describe the public contract and its externally relevant constraints, not the implementation. Keep the rationale when it explains a safety, FFI, ABI, ownership, lifecycle, ordering, persistence, compatibility, protocol, platform, build, or test invariant. Delete implementation history, caller-specific explanations, task language, and obvious narration. Preserve provenance and license information when the repository requires it, but state whether the file is derived from, adapted from, or copied from the named source. Do not imply that the whole file came from an upstream source when only part of it did. Never include a line number, character range, or other fragile source location.

Keep inline comments shorter than item documentation. Explain why the code is non-obvious. Do not narrate the next statement. A platform-dependent Rust file starts with a module comment naming the platform and facility it uses. Preserve required copyright and license notices.

Wrap prose at the Rust house-style limit of 100 columns. Wrap between sentences or at clause boundaries, never inside a sentence at an arbitrary point, and never capitalize a word to justify a line break. A wrapped line continues the same sentence; a period appears only where a sentence ends. Use headings only for distinct subjects, and name the subject rather than the reader's experience. Remove emphasis formatting from comments unless the formatting is part of a real structural element such as a code span or link.

Rewrite means rewrite: restate each comment's content in the target register rather than swapping individual words. Changing "Ported" to "Adapted" or "a caller" to "the caller" while leaving dense or rhetorical prose intact does not meet this standard. Conversely, condensing must preserve every distinct fact: if the original gives a reason, the rewrite states that reason.

## Review

Read the whole file before editing it. Review every comment in the file, not only comments found by a search. Check each changed comment against the surrounding code and the authoritative documents. Preserve every meaningful decision, caveat, number, cross-reference, and test condition. Check that deletion does not remove safety, compatibility, lifecycle, protocol, or test rationale. Check that rewritten comments contain no history, task language, caller assumptions, fragile locations, rhetorical framing, self-reference, duplicated facts, or generated-sounding signposting. When an original comment gave diagnostic guidance (which outcomes are routine and which indicate a fault), keep that distinction.

Use `git diff --check`. Confirm that the diff changes comments only. Read the rewritten comments as prose, start to finish: a rewrite that inserts a period at every wrapped line, capitalizes mid-sentence, or leaves sentences that no longer parse is defective regardless of what it removed. Run the repository's prescribed format and test checks after the batch is complete.
