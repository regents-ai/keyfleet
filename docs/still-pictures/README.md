# Per-key still pictures

6 October 2026. Each revealed key's marketplace picture is its card, seen from the outside, as a still picture.
Sean accepted the Key Lab card design on 6 October 2026 ("1. a"). This folder holds the trait table, eight fixed
test keys, the script that draws them unattended, and the check that the site draws the same traits. It ran on this
Mac only. No storage, job, Fly machine or money was used; production storage and the job that makes pictures each
need their own go.

## What ran

- **Page.** The Key Lab, version 9 of https://claude.ai/artifact/F2yTo8YVpAVCwQzWZcRRZv. A link of the form
  `#seed=0x…&key=N&fleet=classic&fleetNumber=1&open` opens that key's card with its top line.
- **Draw.** The trait table file from that page, `0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8`, named by its fingerprint: 8 traits of 16 values
  each, every trait's weights adding up to 1,000. It shipped with the site until 7 October 2026, when Sean's new odds
  replaced it with `platform/priv/trait_tables/0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe.json`: the same values in the same places, with new weights.
  Everything on this page was drawn from the 6 October table.
- **Keys.** `keys.json` holds eight fixed test keys. Seed n is `0x` followed by the sha256 of
  "keyfleet still test n".
- **Rendering.** `render.mjs` opens each key in headless Chromium with reduced motion and saves the card as a
  767×959 PNG at `art/<table hash>/<slot>/<key>.png`.
- **Parity.** `parity.exs` loads the table file through the site's own reader, `Keyfleet.Traits.table!/1`, which
  checks the fingerprint, then draws the same eight keys with `Keyfleet.Traits.draw/2` and compares them with what
  the page showed.

## Results

| Check | Result |
| --- | --- |
| Draws on a computer with no graphics chip | Yes. Chromium's CPU renderer (SwiftShader, the kind a Fly machine would use) drew all eight with no errors. |
| Same picture every time | Yes. Separate CPU runs gave byte-identical files for all eight keys. |
| Same traits as the site | Yes, 8 of 8 traits for all eight keys, through the site's own table reader and draw. |
| Picture address matches the key's metadata | Yes. Metadata names the card at `https://media.regents.sh/ipfs/<cid>` and `ipfs://<cid>`, the address IPFS gives its bytes. |
| Never changes once made | Yes. The table's fingerprint is part of the path, and the same seed, table and top line always give the same bytes. |

Drawn as Classic #1:

| Key | Exterior Design | Emblem | sha256 of the CPU picture |
| --- | --- | --- | --- |
| 1 | Signal | Leaf | `c6394293f7d8e0d5137c5712589b25b3ae24bcc2a218c0e4952dac6c8c3d1880` |
| 2 | Lantern | Eye | `2bc2f264e2a205ebef339fe49030eb432361e41f15af30c3cda1b4d281fbda00` |
| 3 | Observatory | Anchor | `95818b2e1e136b51245f4b7cf7c99bb452975475841b7367497da833a9656ba5` |
| 4 | Lantern | Leaf | `7345d22f13c94525a52526f2899781b91cd169ba11bc559d0af9e42ab8e6ac1b` |
| 5 | Circuit | Wave | `2d05a871753782c87586129d9d11fe014cb82b7c8e6ba5dfafdec651e57e08fc` |
| 6 | Labyrinth | Anchor | `6fd84c058eca68c892d819b9c71bf6c796f9861ff30ccf0f8f00685800e94ab2` |
| 7 | Tidewater | Star | `2332201c9eadf4cd8029e84d76885eef471f031bb81272aa6d0e5c268a84e423` |
| 8 | Circuit | Wave | `3531cfec9ca32e4ab009cc0c5396f431d760120033ff10438ea29c0e9bd90bd0` |

Until a key's traits are drawn, its metadata shows the Interim Keyfleet Access Pass instead; see
`interim-pass/README.md`.

## In the site (7 October 2026)

Sean's "2. a" of 6 October 2026 asked for the per-key pictures, built locally first.

- **Drawing.** [key-art/](../../key-art/README.md) is a small private service: one page bundles the site's own
  `platform/assets/js/key_card` code and draws the card off screen; `POST /draw` answers the PNG. On this Mac all
  eight test keys came out byte-identical to the table above, through the site's own client too.
- **On Linux.** In the service's image (Chromium's CPU renderer on arm64) every key draws the same bytes every time,
  but about 1% of pixels, mostly letter edges, differ slightly from the Mac's. A picture never changes once stored,
  so this matters only when comparing with the Mac. Fly's amd64 machines have not been tried.
- **Storing.** Each recorded reveal queues a job that draws the card, keeps it on IPFS through Regent's Lighthouse
  account and records its address against that reveal; the key's metadata then names it. Until then the key shows
  the Interim Keyfleet Access Pass.
- **Fleet numbers.** Each fleet's top line comes from the site's catalog (`CLASSIC #1`, `SYNDICATE #1`, …); no
  contract change.

## Run it again

The 6 October table is no longer in the tree; take it from the last commit that had it.

```sh
git show aecccaa:platform/priv/trait_tables/0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8.json > <out folder>/0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8.json
node docs/still-pictures/render.mjs <saved Key Lab page> <out folder> classic 0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8 classic 1
cd platform && MIX_ENV=test mix run --no-start ../docs/still-pictures/parity.exs <out folder>/0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8.json ../docs/still-pictures/keys.json <out folder>/report.json
```
