# Frame trace

The development desktop adds Start frame trace, Stop frame trace, Export frame trace, and Cancel frame trace to the wrist menu's Development group. The plugin starts idle and opens no panel. Start replaces the previous capture. Stop retains completed rows. Cancel discards the capture. Completion, cancellation, callback errors, runtime shutdown, and source reload release the public native observation subscription. The timer module must be enabled. A custom `lovr.run` override is not observed.

Export writes `frame-trace.csv` atomically in LÖVR's save directory after observation stops. The log reports the path. A later export replaces that file, so an A/B workflow copies each exported file before the next export. File errors use the normal error stream. Capture duration and capacity are bounded by the entry's schema in `init.luau`; reaching either bound stops observation. Export allocates CSV text only after capture. The capture stores primitive fields in preallocated rows and does not retain native records.

## Timing alignment

The CSV format version is 1. Empty fields mean unavailable, not zero. Durations are seconds. `syncTime` is the clock immediately after `headset.update`, or at the corresponding frame boundary when no headset module is loaded. `interval` spans successive boundaries. `sync` measures elapsed headset update time, including its wait, and is absent without a headset module. The remaining phase durations describe work following that sync. Draw includes obtaining passes and the window mirror callback. Host collection runs after LÖVR yields, outside native headset work timing. `betweenFrames` includes collection, compilation installation, and control chunks, but excludes observer publication and the final platform yield. Audio, event dispatch, snapshot preparation, and other unmarked work remain outside individual phase fields.

The native frame timing is read at sync. Its `nativeWork` belongs to preceding work, while the row's phase durations belong to following work. The analyzer compares long intervals and native predicted-target misses with the previous contiguous row's completed phases and collection. It does not align across sequence gaps. Native `skipped` counts missed predicted targets, not actual presentation count. A long sync interval is a separate observation and can occur while `skipped` is zero.

Heap values ending in `KiB` are net Luau heap samples at boundaries. Their differences include collection and do not count allocations or temporary churn. Missing phase boundaries prevent a corresponding heap delta. Metadata retains active, visible, and focused headset state, foveation, configured supersampling and antialiasing, the active compilation mode, GPU-timing state, and the host collection budget and report. Focus loss is reported as unfocused; on OpenVR it identifies dashboard visibility. Dashboard-open captures are legitimate and must use the same state in both comparison runs.

## Analysis and overhead

```sh
python3 dev/tools/analyze_frame_trace.py capture-a.csv capture-b.csv
make check-frame-trace
```

The analyzer validates the versioned CSV wire and emits JSON summaries. `longIntervals` uses intervals above 1.5 refresh periods. `predictedTargetMisses` uses the native estimate independently. Both report preceding work and net heap means, while missing measurements remain absent. The metadata sets reveal changes that invalidate a comparison.

Observation adds clock reads, seven heap samples on the full graphics/headset path, one native frame-timing table read, metadata getters, Rust/Lua boundary calls, and one callback with primitive copying per completed frame. `observer` measures only the host sampler's mark and metadata time. It excludes callback dispatch, field readers, record copying, Rust publication, and some clock-call overhead. It is a lower bound, not a correction to subtract from work. The tracer never enables GPU timing or calls graphics timing readbacks. An already-open Performance panel can still enable GPU timing; close it for comparisons unless its cost is part of both runs.

No fixed observer cost is assumed. Instrument both A and B with the same duration, capacity, rendering configuration, focus state, compilation mode, GC budget, warm-up, and workload. Repeat runs in alternating order and retain all exports. Compare long-interval rates and preceding work separately from native skipped-target estimates. Compare instrumented runs with independent uninstrumented runtime measurements before attributing small differences. Preallocation happens before observation and can affect the first interval, so exclude the first row's unavailable interval and use a consistent warm-up. No live-headset overhead result is supplied by these tests.
