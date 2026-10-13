# Arrangement persistence

The `desktop/persistence` provider saves and restores panel poses, sizes, and tags.

| Provides | Requires |
| --- | --- |
| `lunette/arrangement` | `lunette/drops`, `lunette/frame`, `lunette/panels`, `lunette/rules`, `lunette/tags` |

[Options](config.luau) · [Contract](../../lunette-contracts/arrangement.luau) · [File format](format.luau) · [Persistence behavior](docs/persistence.md)

A window holds its saved slot until it dies. The slot is keyed by application id and slot number, so a later window can reuse it. Holding slots avoids consuming them during rule previews and prevents provider outages from shuffling still-live windows. Monitor panels restore when they appear.

Unreadable files and files from newer versions are reported and never overwritten. The provider saves on a completed drop and at quit, not on panel removal: removal also occurs during outages and reloads. A quit-save error is reported without vetoing quit.