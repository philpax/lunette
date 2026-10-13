# Window pacing

`@lunette-plugins/desktop/pacing` applies a frame rate to each window panel from its visibility and window activity, and can pause hidden monitor captures. The shipped desktop uses entry `desktop/pacing`.

The entry requires `lunette/frame`, `lunette/panels`, and `lunette/pacing`. [`config.luau`](config.luau) is the source of truth for `pauseMonitors`, which defaults to true. The pacing contract supplies a resource-free pacer for each window; [Pacing policy](docs/pacing-policy.md) specifies how the consumer observes commits and restores changes. Shared native rate limits and output refresh mechanisms remain in [Rendering](../../../../docs/dev/rendering.md#frame-pacing) and [Frame pacing and output scale](../../../../docs/dev/lua-api.md#frame-pacing-and-output-scale).

The default tuning runs hidden quiet windows at 1 Hz, and hidden video, game, or busy windows at 30 Hz; shown panels are unthrottled. Unloading the entry restores windows to unthrottled operation and resumes monitors it paused. Tests: [`pacing.luau`](tests/pacing.luau).

The provider/consumer split, unload behavior, and deliberately unimplemented view-based policies are specified in [Pacing policy](docs/pacing-policy.md) and [Standard plugins](../../../../docs/dev/standard-plugins.md#pacing-and-scale).
