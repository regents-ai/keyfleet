# Key-art service

Draws a revealed key's card as a 767×959 PNG for the site's picture job
(`Keyfleet.Keys.DrawPicture`). It runs on its own small private Fly machine,
`keyfleet-key-art`, and only the site talks to it.

- `page/still.ts` bundles the site's own card code (`platform/assets/js/key_card`)
  and draws the card off screen, so the picture is the same card the Key Lab and
  the early-access page's roller show.
- `server.mjs` keeps one headless Chromium (CPU rendering, no graphics chip) and
  answers:
  - `GET /healthz`: 200 once the browser is up.
  - `POST /draw` with JSON `{"seed", "top_line", "table"}`: 200 and the PNG;
    400 and `{"error": <reason>}` for a body that is not JSON with those three
    strings; 422 and `{"error": <reason>}` for a seed that is not 32 bytes of
    lowercase hex, an empty top line or a table other than
    `0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8`.
- The same seed, table and top line always give the same bytes on one kind of
  machine. Mac and Linux pictures differ in about 1% of pixels (letter edges);
  see [docs/still-pictures/README.md](../docs/still-pictures/README.md).

## Run it on this computer

The build reads the card code's packages from `platform/node_modules`, so run
`npm ci` in `platform/` first.

```sh
cd key-art
npm ci
npm run build
PORT=4890 npm start
```

The site's development settings point at `http://127.0.0.1:4890`. `npm run
typecheck` checks the page against the site's TypeScript settings.

## Going live

Nothing here goes on Fly without the founder's go.

1. Create the app without public addresses and give it a private one:
   `fly apps create keyfleet-key-art`, then
   `fly ips allocate-v6 --private --app keyfleet-key-art`.
2. Deploy from the repository root:
   `fly deploy --config key-art/fly.toml --dockerfile key-art/Dockerfile --ignorefile key-art/Dockerfile.dockerignore --no-public-ips .`
3. Set `KEY_ART_URL=http://keyfleet-key-art.flycast` on `keyfleet`, then release
   KeyFleet.

The machine sleeps when idle and wakes on the next draw; the job allows two and
a half minutes for that.
