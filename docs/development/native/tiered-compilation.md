# Tiered compilation

Tiered compilation compiles Luau functions to native code once they become hot, without source markers. A session runs arbitrary user and plugin code, so the host cannot know in advance which modules deserve `--!native`, and compiling everything costs startup time and code arena on every reload. `lunette --luau-execution tiered` selects it; the default remains O1 interpretation.

## Mechanism

The Luau fork gives each function prototype a counter. Functions loaded while a hot threshold is set start at that threshold and count down once for each interpreted entry and each loop back-edge. Entries count whether they come from a call instruction, from C, from a protected-call fast path, or from native code calling an interpreted function. A function whose count reaches zero joins a bounded queue. A full queue rearms the counter instead of growing, so the execution path never allocates. Collecting a queued prototype removes it from the queue.

`Luau::CodeGen::compileHot` compiles queued functions oldest first until the next one would exceed a bytecode instruction budget, always taking at least one. It compiles each function alone, without its nested functions, and ignores the compiler's cold-function heuristic, because the counter is runtime evidence. A native module sorts and binds its functions by bytecode id, which is unique only within one loaded chunk, so a batch splits into modules whose ids do not collide.

LÖVR's tiered scope compiles `--!native` modules and `@native` functions at load, as the marked scope does, and leaves everything else to promotion. Leaving the tiered scope stops newly loaded functions from counting and keeps queued functions valid. `lunette::execution` exposes the mode, its parameters, promotion, and the queue length; [`execution.rs`](../../../crates/lunette/src/execution.rs) documents the contract.

The session promotes after each frame ends and before the next begins, beside control-chunk draining, so compilation never runs inside a callback. [`boot.rs`](../../../crates/lunette/src/boot.rs) owns the threshold, queue capacity, and per-frame budget. A CPU or build without native compilation starts the session interpreted and logs why.

## Limitations

There is no on-stack replacement. A frame already running a promoted function finishes in the interpreter, and a coroutine suspended inside one resumes there; the next call enters native code. Frame callbacks return every frame, so this delays promotion by at most one call in practice.

There is no deoptimisation. Native code guards its assumptions and exits to the interpreter for a block when a guard fails, as it does under the other native modes.

Promotion only reaches the speed of all-native compilation for the functions it promotes; it runs the same generated code. Allocation, garbage collection, and Lua API conversion keep their cost.

The CodeGen arena never reuses freed blocks, as [the LÖVR integration notes](lovr-integration.md#native-compile-cost) record for all-native compilation. A source reload creates new prototypes, which become hot and promote again, so arena reservation still grows with each reload, by the size of the hot set rather than of every loaded module.

Sessions protect the standard library and mark the environment safe, so promoted code takes builtin fast paths. Imports are still looked up when they run rather than resolved at load.

Counting adds a decrement and a branch to every interpreted call and back-edge of a counting function. A promoted function stops counting, and a function that never becomes hot keeps counting.

## Results

The Steam Frame is the target. Its measurements use the desktop benchmark with `--renderer hardware` on one pinned performance core, eight paired rounds, and 600 warmup and 600 timed frames. Callback CPU is the update and draw thread CPU. Raw captures stay local in the ignored `docs/development/benchmarks/` directory.

A threshold of 1000 promoted about 460 functions and lost to marker-only compilation in every round on the Frame, although it beat all-native compilation on an x86-64 workstation. Promoting lukewarm functions cost more than it saved on ARM64. A threshold of 10000 promotes about 220 functions and wins.

A budget of 1000 instructions produced promotions of about 3 ms in one frame. A budget of 250 keeps most promotions under 1 ms, but one large function still takes about 1.7 ms, because the first queued function always compiles. Counting costs about 0.6% of callback CPU against O2 interpretation, which is within the observed variation.

Before sessions protected the standard library, native code of any kind saved only 2 to 5% of Frame callback CPU, because every builtin call fell back to a C call. With builtin fast paths, tiered compilation reduces callback CPU by about 9.6% against O1 interpretation and by 4.1% against marker-only compilation, winning every round, and halves the geometry workload. It compiles in about 55 ms against about 250 ms for all-native compilation, and reserves 4 MiB of code arena after three reloads against 40 MiB.

[`boot.rs`](../../../crates/lunette/src/boot.rs) uses these results for its threshold and budget. Live headset sessions and long reload sequences remain unmeasured.

## Measuring

The desktop benchmark measures tiered compilation beside the other modes. `o2-tiered` promotes between warmup and timed frames, as the session does, and reports promotion thread CPU separately from callback CPU, with per-frame warmup series that show convergence. `o2-counting` counts without promoting, which bounds the counters' interpreter overhead against `o2-interpreter`; it runs only when `--modes` names it. `--tier-threshold`, `--tier-queue`, and `--tier-budget` set the parameters. [Build and development](../build-and-development.md#desktop-benchmarks) describes the harness and its offscreen renderer.
