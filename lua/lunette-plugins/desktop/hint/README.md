# Empty-desktop hint

Draws configured text while the panel registry has no panels. Configure the text, [`position`, and text appearance](config.luau).

| Requires |
| --- |
| `lunette/frame`, `lunette/panels`, and `lunette/theme` |

Any registered panel suppresses the hint, including a hidden panel. Panel lifetime and visibility follow the shared [panels contract](../../../../lua/lunette-contracts/panels-and-ui.md#panels).
