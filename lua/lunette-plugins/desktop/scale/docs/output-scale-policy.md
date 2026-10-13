# Output scale policy

`desktop/scale` updates in the `overlay` phase. For each output, it measures the distance from the head to each shown window panel whose window uses that output. It selects the nearest panel and passes that distance to the output's resource-free `lunette/scale` chooser. Monitor panels, hidden panels, dead windows, and windows without a live output do not contribute a distance.

The consumer applies a new output mode only when the chooser's step changes. An output with no shown window panel keeps its scale. If the headset reports no head, the consumer makes no changes. The scale ladder is the one used by the layer pool; see [The layer pool](../../../../../docs/dev/rendering.md#the-layer-pool) and [Frame pacing and output scale](../../../../../docs/dev/lua-api.md#frame-pacing-and-output-scale).

## Restore on unload

The consumer records an output's original scale the first time it changes that output. On unload, it restores the original scale only if the output is live and still has the scale this entry applied. If another plugin changed the scale after this entry, the consumer leaves that value alone. The entry has no configuration fields.

## Decisions

Scale is a provider and a separate desktop consumer. A different scale policy is a different provider, and a different reading of the scene is a different consumer. The desktop entry reads the scene and applies the provider's answer. The default entry is enabled and reverts its change on unload, because a disabled entry must not leave outputs at a step it chose. Shared policy boundaries remain in [Standard plugins](../../../../../docs/dev/standard-plugins.md#pacing-and-scale).
