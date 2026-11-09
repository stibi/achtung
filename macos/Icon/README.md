# App icon

`AppIcon.svg` is the app icon: the krysa (the pixel rat from the GitLab maintenance page in
`iac.git`) with a green beacon, inside the brackets of the AGRP[DEV] wordmark. Colors and
shapes follow agrp.dev: black, AGRP green `#29df2b`, white.

`alternatives/` keeps the other proposals:

| File | Idea |
|---|---|
| `krysa-on-bang.svg` | The `[!]` mark with the beacon krysa standing on top of it |
| `bang-beacon.svg` | `[!]` where the dot of the "!" is the krysa's beacon |
| `bang.svg` | `[!]`: the wordmark brackets around a white "!" |
| `krysa-achtung.svg` | The krysa with a pixel speech bubble shouting "!" |
| `beacon-krysa.svg` | The krysa with a beacon on its back, no brackets |
| `prompt.svg` | A shell prompt and cursor, with a tiny krysa running along the bottom |
| `startled-krysa.svg` | A front-facing krysa portrait with glowing green eyes |

To switch, copy one over `AppIcon.svg`, then render the icon set and rebuild:

```bash
swift macos/scripts/render-icon.swift   # writes Achtung/Assets.xcassets/AppIcon.appiconset/*.png
```

The PNGs are committed, so a normal build doesn't need this step. Pixel squares overlap
their neighbours by one unit; renderers that ignore `crispEdges` would otherwise show
seams between them.

`coffee-break/` has the krysa's coffee break, Live's "All caught up" scene, as looping
GIFs to share, rendered from the app's own scene by `macos/scripts/render-coffee-break.sh`
(see its README).
