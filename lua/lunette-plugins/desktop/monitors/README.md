# Monitor mirrors

Mirrors selected host monitors into panels. Configure [`select`, `placement`, and `tags`](config.luau); an empty selection includes every monitor.

| Requires | Optional |
| --- | --- |
| `lunette/panels` | `lunette/tags` for the tagging child |

Each new mirror takes the lowest free place in the row. Existing mirrors do not move when monitors arrive or disappear, because saved arrangement restores each mirror as it appears.

A tag-provider outage stops tagging but leaves mirroring active. Monitor capture and permission workflows depend on the host desktop; see [Monitors and titlebars](../../../../docs/guide/desktop-configuration.md#monitors-and-titlebars).
