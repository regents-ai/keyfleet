# Third-party notices

Third-party material redistributed inside this repository, and the terms it arrives under.

## vgpu — account holographic card

The foil on the account page's identity card is the shared `Regent.HolographicCard`
from the Regent design system, whose `holographic_card.mjs` adapts the "Holographic
Card" example published with Vercel's `vgpu` project. This repository ships no copy of
that material: `mix regent_ui.assets` stages the module from the pinned design-system
revision at build time, and the attribution and licence text live in the design system's
`THIRD_PARTY_NOTICES.md`. The renderer runs on the `vgpu` 0.6.0 this repository
pins, with `@vgpu/wgsl` 0.6.0 preparing its shader.

## vgpu — crown renderer

The glass crown under `assets/js/crown/` began as the prism scene from Vercel's `vgpu`
project. Its camera, pass structure, post-processing, crown mesh and WGSL are adapted
from that work. One crown serves every Regent site; a site supplies only its look.

- Project: `vercel-labs/vgpu` — https://github.com/vercel-labs/vgpu
- Commit: `bd3b05101fdd1193a1593558d3c52a0b2b18f31d` ("feat(docs): move prism shader to homepage")
- Source directory: `apps/docs/app/[lang]/(home)/components/prism-background`
- License: MIT

Pinned npm packages, exact versions, no ranges:

| Package         | Version |
| --------------- | ------- |
| `vgpu`          | 0.6.0   |
| `@vgpu/wgsl`    | 0.6.0   |
| `@webgpu/types` | 0.1.69  |

### What was taken

The camera and pass structure, and the production shaders `copy-linear`, `bloom`,
`bloom-upsample` and `present`, together with the colour functions of
`@vgpu/wgsl-std/color` and the upstream `environment.wgsl` studio that the glass
reflects.

The visible solid is the Regents 3/5/5 crown: thirteen disconnected glass cubes in
place of the upstream triangle prism. Its mesh (`assets/js/crown/mesh.ts`) and its
front and back glass shaders are structural adaptations of the upstream prism mesh
and its `glass` and `glass-back` shaders. The beam tracer (`assets/js/crown/light.ts`)
and its additive sheet shader are adapted from the upstream spectral light sheet.

### What was left behind

The React component and its control panel, the debug renderers and view modes, the
wireframe paths, the triangle prism mesh, the `wall` shader, the thumbnail renderer
and the upstream test suites.

### Where the crown came from

The crown is the copy every Regent site shares, taken from ash-template. It was first
built for the Regents Labs homepage, and this repository carried a copy of that crown
until the shared one replaced it. Its mesh and its front, back and common glass shaders
were supplied in the standalone `regents-vgpu-crown` source bundle, whose sorted
source-bundle digest is
`f1235c2f53db30addf70846bb4d4c8675277eeba0794c8c583de7bb63d6678ed`.
That bundle identifies its crown work as a structural adaptation of the same vgpu
prism example at the pinned commit above. Its exact source SHA-256 values were:

| Source | SHA-256 |
| ------ | ------- |
| `crown-types.ts` | `cb5e9c0adb24b68e09336f1c1c4b0fedb73545567ab7671b4699730789e2dbd8` |
| `crown-mesh.ts` | `95c99de93bc9c33a03c6cc6da36210a9e30af70517ec2a56726d22a0481993f2` |
| `crown-glass-common.wgsl` | `aa0df4059483fd58b9fd181cb8465304a5125b2934128eaa9f932b74d93d0de4` |
| `crown-glass-front.wgsl` | `2522c4ecd14b3966c5278f01689f82b08291bb80561557bda5d82198c2191bac` |
| `crown-glass-back.wgsl` | `f1ef00628482d8e7ddfb2e41c4c86ac5fdd31a58f32e2b6246a5fdd241d21df5` |
| `crown-mesh.test.ts` | `b415cec1bf6f90f79d37ab4797556bb0c32d00d733d5d2981e4221a594638be7` |
| `THIRD_PARTY_NOTICES.md` | `da6af60647c0f6601d64782e18cc682c6270b6e63e4e7e02fd41c83977340ec3` |

The beam tracer, its sheet shader, the camera and the field of squares behind the
crown (`assets/js/crown_looks.ts`) arrived by way of a sibling product, which
adapted them from the same prism background.

The upstream `environment.wgsl` the glass reflects is the file at the pinned commit
and path above, SHA-256
`382157376c95468a7a9ad1b5c50ba4d630aa3ec15589e7c86041b074d6f54d90`.
The `@vgpu/wgsl-std` 0.3.1 colour input the shaders were joined with has SHA-256
`9a65713c22469c7aea102286385e00d5ac8c5986bb415384af779c04fbf88401`.

### How the shaders got here

Each shader under `assets/js/crown/shaders/` is a plain WGSL string. Those that came
from more than one upstream module were joined once, offline, with identifiers kept,
and carry a `vgsl-module:` comment naming each module they hold. Nothing is downloaded
at runtime: `@vgpu/wgsl` prepares each string in the browser when the crown first draws.

### License

```
MIT License

Copyright (c) 2025 Vercel, Inc.

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
