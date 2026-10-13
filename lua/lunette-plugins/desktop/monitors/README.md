# Monitor mirrors

`@lunette-plugins/desktop/monitors` mirrors selected host monitors into native monitor panels and handles monitors added while the entry is active. The shipped desktop uses entry `desktop/monitors`.

The entry requires `lunette/panels`. The optional tagging child requires `lunette/tags`; without that child, monitor mirroring remains active when the tags provider is unavailable. [`config.luau`](config.luau) is the source of truth for `select`, `placement`, and `tags`. An empty `select` mirrors every monitor. The placement fields use a vector center, width, and non-negative gap. [Monitor placement](docs/monitor-placement.md) specifies row assignment and tagging.

The panels contract owns monitor texture and panel behavior. [Monitors and titlebars](../../../../docs/guide/desktop-configuration.md#monitors-and-titlebars) describes capture and portal workflows; [Titlebar behavior](../decorations/docs/titlebar-behavior.md) specifies monitor titlebar actions. Tests: [`monitors.luau`](tests/monitors.luau).

## Known gaps

Host capture availability and portal permission behavior depend on the host desktop. Shared capture mechanisms and acceptance remain in [Host desktop](../../../../docs/dev/host-desktop.md) and [Build and development](../../../../docs/dev/build-and-development.md).
