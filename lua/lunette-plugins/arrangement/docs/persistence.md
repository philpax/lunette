# Arrangement persistence

The `desktop/persistence` entry provides `lunette/arrangement`. Its factory keeps loaded state and held window slots across activations that use the same `file`. The activation-scoped rule source and panel-arrival listener end when the provider unloads. The provider requires the drops, frame, panels, rules, and tags contracts. Its configuration schema is [config.luau](../config.luau), and the versioned file format is defined by [format.luau](../format.luau).

## Identity and slots

A window is saved under its application id and a monitor under its id. A window holds a slot from the creation of its panel until it dies. When that window dies, its slot becomes available; a later window with the same application id can reuse a free slot. The saved match uses the application id and slot, not the identity of the old window. Taking a slot on every resolve would let `rules:resolve` consume slots. Freeing a slot when the panel is removed would let a provider outage, which removes every panel while the windows remain, shuffle windows between slots.

A monitor panel that appears later is restored as it appears. A saved entry that matches nothing is reported once per arrangement. The state is made at the first activation and kept across activations with the same `file`. The rules source and arrival listener are effects of the activation.

## Save and restore lifecycle

A file the provider cannot read, or one from a newer version, is reported and never overwritten. The provider saves when a drop is announced and at quit. A quit-save failure is reported and does not veto the quit. The arrangement contract in [arrangement.luau](../../../lunette-contracts/arrangement.luau) defines the service methods; the drops and frame contracts define the shared notifications.

Saving on panel removal was rejected because removal happens mostly during outages, reloads, and unloads, when the desktop is coming apart. A drop is the moment the user finishes placing a panel.

## Decisions

A saved slot is held by its window. Taking a slot on every resolve would let `rules:resolve` consume slots. Freeing a slot when the panel is removed would let a provider outage, which removes every panel while the windows remain, shuffle windows between slots.

The arrangement is saved on a drop and at quit. Saving on panel removal was rejected because removal happens mostly during outages, reloads, and unloads, when the desktop is coming apart. A drop is the moment the user finishes placing a panel.

The format implementation in [format.luau](../format.luau) is the source of truth for serialization and validation.