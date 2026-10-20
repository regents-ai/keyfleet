# Third-party notices

Third-party material redistributed inside this repository, and the terms it arrives under.

## vgpu — account holographic card

The foil on the account page's identity card is the shared `Regent.HolographicCard`
from the Regent design system, whose `holographic_card.mjs` adapts the "Holographic
Card" example published with Vercel's `vgpu` project. This repository ships no copy of
that material: `mix regent_ui.assets` stages the module from the pinned design-system
revision at build time, and the attribution and licence text live in the design system's
`THIRD_PARTY_NOTICES.md`. The renderer runs on the `vgpu` this repository pins in
`package.json`.

## Geist — share pictures

The share pictures in `priv/static/images/keyfleet-share.png` and `priv/share/`
are drawn in Geist, Geist Mono and Geist Pixel, which the Regent design system
ships under the SIL Open Font License 1.1. They are pictures made with the
fonts; no font file is copied into this repository.

## thiings-grid — key map camera

The key map's drag and coast began as the camera in Charlie Clark's `thiings-grid`.
`assets/js/hooks/key_map/camera.ts` is a rewrite of that behaviour, not a copy of
the file, and carries a header comment pointing here.

- Project: `charlieclark/thiings-grid` — https://github.com/charlieclark/thiings-grid
- Commit: `a1607d3cee9e6969f5f504f0c253ee94aa50bf54`
- Source file: `lib/ThiingsGrid.tsx`
- License: MIT

### What was taken

The feel of the drag and the throw: release speed from the last five pointer
samples, weighted toward the most recent; no throw when the pointer rested before
letting go; the release speed scaled by 16 into pixels per 60 Hz frame; friction
of 0.997 per millisecond, applied over the real time between frames; the coast
ending below 0.05; and the wheel panning the grid by its deltas. The constants keep
their upstream values.

### What was left behind

The React component and its render props, the square grid and its spiral item
ordering, the throttled item updates and the debounced moving flag, the separate
mouse and touch listeners, and the fixed 16 ms update step. The key map places hex
tiles from its own pool, uses pointer events with pointer capture, tells a tap from
a drag by distance travelled, stops a coasting map on a press without choosing a
key, honours the wheel's line and page units, runs frames only while the map moves,
and does not coast under reduced motion.

### License

```
MIT License

Copyright (c) 2025 Charlie Clark

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ActiveGraph — fleet work graph

Each fleet's shared work graph runs on ActiveGraph inside the private Python host
under `graph_host/`. The host installs it as a dependency; this repository carries
no copy of its source.

- Project: `yoheinakajima/activegraph` — https://github.com/yoheinakajima/activegraph
- Commit: `8aedb1866cf5dce056af97529152ffd6f468a1ed` (package version 1.10.0)
- License: Apache License 2.0

`graph_host/pyproject.toml` pins that commit and `graph_host/uv.lock` records it. The
host test suite fails if the installed version or commit differs. The upstream
`LICENSE` and `NOTICE` are kept verbatim under `graph_host/third_party/activegraph/`,
and the release image copies them to `/opt/graph_host/third_party/activegraph/` beside
the installed package.
