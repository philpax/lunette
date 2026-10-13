# Audio provider

The provider exposes non-routing PCM readers for the system output mix and registered session processes. It does not change routing or volume. Capture starts when a consumer opens a reader.

| Provides | Requires |
| --- | --- |
| [`lunette/audio`](../../lunette-contracts/audio.luau) | `lunette/frame` |

Readers open capture on demand and are owner-scoped. Consumers select the system mix or a registered logical process, then track block sequence and stream generation when processing retained snapshots. The [shared audio specification](../../../docs/dev/audio.md#non-routing-capture) covers capture behavior and pending live acceptance. [The audio-backdrop meter](../../../examples/audio-backdrop/meter.luau) demonstrates raw and analysed readers.
