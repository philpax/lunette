# Arc geometry

The `layout/arc` entry registers a layout with the layouts broker. It places panels around a vertical circle and rotates each panel to face the circle's centre. The schema in [config.luau](../config.luau) owns the registered name and tuning defaults.

## Angular spacing

The layout preserves the order of panels supplied by the caller. For each adjacent pair, it calculates the angular separation needed for both panel half-widths at the configured radius, plus the configured edge gap divided by the radius. It uses the larger of that value and the minimum angular step. If the sum of separations exceeds the configured span, it scales every separation by the same factor until the first and last panels fill the span. In that case panels may overlap. Otherwise they keep both the minimum step and the edge gap.

The arc is centred on angle zero. Positive angles turn left. One panel therefore sits at the centre angle. The pose for each panel places it on the configured circle at the configured centre height, then rotates it around the vertical axis to face the centre.

The schema defaults are radius 1.6 m, minimum step 0.55 radians, span `1.2 * pi` radians, edge gap 0.05 m, and centre `vector.pack(0, 1.5, 0)`. The schema is the source of truth for these values.

## Decisions

Angular spacing uses each adjacent pair's widths, rather than a uniform step alone, so panels that fit do not overlap and retain the configured edge gap. The minimum step keeps narrow panels apart. When the requested layout does not fit the span, uniform scaling preserves the ordering and centres the result within the available arc; overlap is accepted at that limit.

The layout reads widths from panels and takes all other geometry from its own entry configuration. Per-tag layout options were rejected because tags are shared state. Per-application options were rejected because they would create a second, untyped home for the arc's configuration.

## Known gaps

The arc is the only shipped layout. The [layout examples](../../../../../examples/layout/) contain grid and follow implementations.