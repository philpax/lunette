# Output scale

`@lunette-plugins/desktop/scale` chooses and applies an output scale from the nearest shown window panel for each output. The shipped desktop uses entry `desktop/scale`.

The entry requires `lunette/frame`, `lunette/panels`, and `lunette/scale`. It has no configuration fields. The scale contract supplies the resource-free chooser and the native API supplies output modes. The consumer considers shown window panels only. An output with no shown window panel keeps its current scale; when the headset reports no head, the consumer changes nothing.

The consumer restores an output's original scale on unload only if the output still has the value this consumer set. The scale ladder and chooser are shared with the pacing and rendering policies; see [Pacing and scale](../../../../docs/dev/standard-plugins.md#pacing-and-scale) and [The layer pool](../../../../docs/dev/rendering.md#the-layer-pool). Tests: [`scale.luau`](tests/scale.luau).

The provider/consumer split and shared scale policy are specified in [Standard plugins](../../../../docs/dev/standard-plugins.md#pacing-and-scale) and [Output scale policy](docs/output-scale-policy.md).
