# Laser provider

Attaches controller input to interaction pointers and draws their beams and feedback.

| Provides | Requires |
|---|---|
| [`lunette/laser`](../../lunette-contracts/laser.luau) | [`lunette/interaction`](../interaction/README.md), [`lunette/theme`](../theme/README.md) |

Each attached hand has one laser owner. Unless its options supply a seat, the laser creates a seat for its pointer. To share one keyboard and pointer authority across hands, both attachments name the same seat. The host input domain remains a single seat.

[Filtering and trigger lock](docs/aim-and-drag-feedback.md) · [Options](config.luau) · [Desktop consumer](../desktop/pointing/README.md)
