# Controller lasers

Attaches controller input to interaction pointers and draws feedback. Aim smoothing uses the same ray for picking and drawing without delaying buttons or grabs. Trigger lock stabilizes a hit during a pull; moving beyond its bounds releases the lock until the next pull.

Each hand creates its own seat unless an attachment supplies one. Both hands must name the same seat to share keyboard and pointer authority. Replacing the draw callback also replaces drag-icon drawing.

[Options](config.luau) · [Contract](../../../lunette-contracts/laser.luau) · [Desktop consumer](../hand-pointers/README.md)
