# Coffee break

The krysa's coffee break, Live's "All caught up" scene in the app, as looping GIFs to
share, e.g. in Teams: the krysa sips its coffee every 7 seconds, an unused fire
extinguisher in the corner, a framed green check on the wall. Same pixels and colours as
the app (`CoffeeBreakScene.swift`, `CoffeeBreakPalette.swift` in `macos/Achtung/`).

| File | Size |
|---|---|
| `coffee-break-light.gif`, `coffee-break-dark.gif` | 448×240, 8 px per pixel |
| `coffee-break-light-small.gif`, `coffee-break-dark-small.gif` | 224×120, 4 px per pixel, for chat |

Each is one 7-second loop at 10 frames a second, with identical frames merged,
looping forever. GIF has no partial transparency, so the steam is blended into
an opaque colour.

To re-render after changing the scene or its colours:

```bash
macos/scripts/render-coffee-break.sh   # writes the four GIFs here
```
