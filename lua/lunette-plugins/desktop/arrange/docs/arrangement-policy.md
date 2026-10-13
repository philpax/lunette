# Arrangement policy

`desktop/arrange` arranges live placements that have no pose. It also excludes a panel dropped while the entry is active and a window with a `lunette.pose` property. The persistence and pose-memory consumers supply the latter properties. The placement service and `desktop/adoption` ordering remain shared composition rules in [Placement](../../../../../docs/dev/standard-plugins.md#placement).

## Candidates and triggers

The entry arranges when it activates, when a placement is announced, when a panel is removed, when a layout registers or unregisters, and when a tag changes. A drop does not trigger arrangement. The entry remembers dropped panels for its activation, because re-arranging on a drop would move other windows as the user lets go of one. A `lunette.pose` property also excludes a window. That keeps a window dragged during an outage of `desktop/arrange` from being arranged again. A record in the drops broker would end with that broker's activation, so the consumer keeps its own dropped-panel set.

A panel is a candidate only when its placement has no resolved pose, the panel is live, the panel has not been dropped during the current activation, and its source window has no string-valued `lunette.pose` property. A layout is applied only when the configured name is registered.

## Tag order

When `tags` is configured, the consumer resolves those names in configuration order and skips names that do not exist. Selected tags are processed before unselected tags, preserving their relative order within each group. The first processed tag that contains a panel claims it for that layout call. A panel in several tags is therefore arranged by the first selected tag, so its pose comes from a layout the user is looking at.

When `tags` is empty, the consumer uses every tag. Candidates not claimed by any tag are arranged last as one group. When `tags` is non-empty, candidates in no configured tag are not arranged.

## Layout registration

The selected layout receives the candidate panels for one tag at a time. Its options come from the configuration of the plugin that registers it, such as `layout/arc`'s `tuning`. Layout options do not belong to tags, which are shared state, or to each application, which would give the arc a second, untyped home. The layout broker itself holds no panels or tags. See [Layout registration](../../../layouts/docs/layout-registration.md) for the layout call shape and built-in layout algorithm.

A layout registered as `continuous` is applied every frame in the `scene` phase. Other layouts run only on the arrangement triggers above. A configured name that is not registered is logged once per name, including the registered layout names. If that layout registers later, the consumer arranges the current candidates.

## Decisions

`desktop/arrange` remains separate from rules and persistence. Placement is an integration of multiple entries, following section 6.5 of the Cordis paper. One policy entry was rejected because replacing the layout, rules, or persistence would require copying all of it.

The arrangement consumer receives placements from the placement contract, which carries resolved properties. `panels:onAdded` reaches every panel without those properties. The placement event therefore supplies resolved placement data, while the panel event handles removals.

A window in several tags is arranged by its first selected tag. Layout options belong to the registering plugin. Options on tags were rejected because a tag is shared state; options passed with each application were rejected because they gave the arc a second, untyped home.

## Known gaps

The arc is the only shipped layout. [`examples/layout`](../../../../../examples/layout) holds grid and follow layouts as examples. The shipped entry's `layout` and `tags` fields are defined in [`config.luau`](../config.luau).
