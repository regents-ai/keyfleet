# Key-art service

Draws a revealed key's card as a 767×959 PNG for the site's picture job
(`Keyfleet.Keys.DrawPicture`). It runs on its own small private Fly machine,
`keyfleet-key-art`, and only the site talks to it.

- `page/still.ts` bundles the site's own card code (`platform/assets/js/key_card`)
  and draws the card off screen, so the picture is the same card the Key Lab and
  the early-access page's roller show.
- `server.mjs` keeps one headless Chromium (CPU rendering, no graphics chip) and
  answers as soon as it starts, while the browser is still starting, so the draw
  that wakes a stopped machine is answered once the browser is up:
  - `GET /healthz`: 200 once the browser is up, 503 while it starts.
  - `POST /draw` with JSON `{"seed", "top_line", "table"}`: 200 and the PNG;
    400 and `{"error": <reason>}` for a body that is not JSON with those three
    strings; 422 and `{"error": <reason>}` for a seed that is not 32 bytes of
    lowercase hex, an empty top line or a table other than
    `0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`.
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

## The homepage's shuffle

`shuffle.mjs` draws the hundred Keys the homepage's next Key card shuffles
through when a mouse points at it, and writes them as one looping animated
WebP, ten cards a second:

```sh
cd key-art
node shuffle.mjs ../platform/priv/static/images/home/next-key-shuffle.webp
```

The cards are real Keys from the trait table, of no fleet's deck, from fixed
seeds unlike the thirty turning cards lower on the homepage. Each is drawn
whole with the site's card code on the graphics chip at 1200×1500, its key
reaching past its card, cut out of the studio and kept at 480×600. It needs
`npm ci` here and in `platform/`, and libwebp's `cwebp` and `webpmux`. A WebP
is the one animated picture with transparency every current browser shows in
a plain image; at this size it is about 1.9 MB, so the page loads it only under
a mouse, once its dust shows.

## Going live

Nothing here goes on Fly without the founder's go.

1. Create the app without public addresses and give it a private one:
   `fly apps create keyfleet-key-art`, then
   `fly ips allocate-v6 --private --app keyfleet-key-art`.
2. Deploy from the repository root:
   `fly deploy --config key-art/fly.toml --dockerfile key-art/Dockerfile --ignorefile key-art/Dockerfile.dockerignore --no-public-ips .`
3. Set `KEY_ART_URL=http://keyfleet-key-art.flycast` on `keyfleet`, then release
   Keyfleet.

The machine sleeps when idle and wakes on the next draw; the job allows two and
a half minutes for that.
