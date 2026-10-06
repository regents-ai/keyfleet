# Per-key still pictures: local test (HQ 78 a)

6 October 2026. This test checks one thing: can a server make each revealed key's marketplace picture from the
Key Lab page, unattended, with the same picture every time? It ran on this Mac only. No storage, job, Fly
machine or money was used. Production storage, jobs and any spend each need their own go.

## What ran

- **Page.** The Key Lab, version 5 of https://claude.ai/artifact/F2yTo8YVpAVCwQzWZcRRZv. A link of the form
  `#seed=0x…&key=N&open` opens that key with its card unlocked.
- **Draw.** `table.json` is the trait table file from that page. Its fingerprint is
  `0x5fe3abfbd1ba92754beffdf0e25434eab75238df534afacc481474fbb6d7b720`.
- **Keys.** `keys.json` holds eight fixed test keys. Seed n is `0x` followed by the sha256 of
  "keyfleet still test n".
- **Rendering.** `render.mjs` opens each key in headless Chromium with reduced motion. That fixes the
  animation clock and skips the unlock animation. The script saves the opened card as a 767×959 PNG at
  `art/<table hash>/<slot>/<key>.png`.
- **Parity.** `parity.exs` draws the same eight keys with the site's own `Keyfleet.Traits.draw/2` and compares
  them with what the page showed.

## Results

| Check | Result |
| --- | --- |
| Draws on a computer with no graphics chip | Yes. Chromium's CPU renderer (SwiftShader, the kind a Fly machine would use) drew all eight with no errors. |
| Same picture every time | Yes. Three separate CPU runs gave byte-identical files for all eight keys. |
| Matches a real graphics chip | Yes, to the eye. On the Mac's own chip (Apple Metal), the average difference is 0.13–0.43 of 255 per pixel. At most 0.63% of pixels differ by more than 16 of 255. The CPU picture is the one to keep, because only it is exactly repeatable. |
| Eyes visible | Yes, on all eight. That includes the small side eyes of Tern, Ibis and Rune, checked at full size. |
| Same traits as the site | Yes, 13 of 13 traits for all eight keys, including Skin. |
| Picture path matches the key's metadata | Yes. Metadata names `<site>/art/<table hash>/<slot>/<key>.png`; the slot is the fleet's name, such as `classic`. |
| Never changes once made | Yes. The table's fingerprint is part of the path, and the same seed and table always give the same bytes. |

| Key | Companion | Skin | sha256 of the CPU picture |
| --- | --- | --- | --- |
| 1 | Tern | Frosted Glass | `7ae5b0e1d05e7e2300cf04e528dadbe4e1af16a6808fe137f5c18612f832dbfd` |
| 2 | Pebble | Sandstone | `f9fb43b585cdba3173d322833a232eed800bd99c53c056d0bb1874355583484a` |
| 3 | Sprout | Moss | `0c8ad92f21a3ba1d3a6d6baaf992b4559d64b431710defbcdb9f47049a69656a` |
| 4 | Pebble | Basalt | `b93b9f04d167d34e195b8310d5eadb55639fb2fa872b4799edc4f0782db19157` |
| 5 | Ibis | Terracotta | `b984406ba49de8d3439efd809317010a8b6c66cc8924d7e97131d0886cff4538` |
| 6 | Rill | Teal | `392f5031faf4f93f7799f25fb5f4083630be55d65413441980c7a9bd4d217953` |
| 7 | Cove | Teal | `405ff42f78f3fb4452e5e2967dc6d26d93715902de50be4c9a5850da7d23c62b` |
| 8 | Rune | Anodized Metal | `352a76cafa9e64ace4eafcfac7dadd41a9255897c3fe1dd145b52e7a2d8aabaa` |

## Gaps before this can go live

1. **The site cannot read this table yet.** `Keyfleet.Traits` expects every trait to have one flat list of
   values. In this table, Skin has one list per companion. The draw rule is unchanged, so only the table reader
   needs to change; `parity.exs` shows the result it must give.
2. **Mark is drawn but not shown.** Seven of the eight keys drew a mark, such as Scarf, Round Glasses or Crown,
   but the 3D companions wear no accessories yet. Those pictures show no mark, while the metadata would list one.
3. **The 16th companion has no figure.** About 1 key in 1,000 draws "To Be Named", which has no figure to show.
4. **Nothing serves `/art/` yet.** The metadata already points there, but the site has no such files or route.
   Where pictures are stored and which job makes them is the production step that needs its own go.
5. **The page lives outside the repository.** The Key Lab is an artifact. A server renderer would need the page,
   or its drawing code, inside the repository at a fixed version.

## Run it again

```sh
node docs/still-pictures/render.mjs <saved Key Lab page> <out folder> classic 0x5fe3abfbd1ba92754beffdf0e25434eab75238df534afacc481474fbb6d7b720
cd platform && MIX_ENV=test mix run --no-start ../docs/still-pictures/parity.exs ../docs/still-pictures/table.json ../docs/still-pictures/keys.json <out folder>/report.json
```

`CHANNEL=chromium` in front of the first command uses the computer's graphics chip instead of the CPU.
