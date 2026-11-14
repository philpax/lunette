# Controller lasers

Attaches controller input to interaction pointers and draws feedback. Aim smoothing uses the same ray for picking and drawing without delaying buttons or grabs. Trigger lock stabilizes a hit during a pull; moving beyond its bounds releases the lock until the next pull. A pull that begins on a drag control, such as a slider or an angle dial, leaves the ray live for the whole pull, because holding it still would fight the drag.

Over another application's scene, a beam draws only while it hovers a surface, holds a grab, or holds a button, and fades out when it stops; `overlayBeam = 'always'` keeps idle beams. A hidden beam still aims, so it appears as soon as it reaches content. On OpenXR, its input also reaches the application beneath, as every overlay input does.

Each hand creates its own seat unless an attachment supplies one. Both hands must name the same seat to share keyboard and pointer authority. Replacing the draw callback also replaces drag-icon drawing.

[Options](config.luau) · [Contract](../../../lunette-contracts/laser.luau) · [Desktop consumer](../hand-pointers/README.md)
