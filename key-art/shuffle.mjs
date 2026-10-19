// Draws the hundred cards the homepage's Key card shuffles through and writes
// them as one looping animated WebP, ten cards a second:
//
//   node shuffle.mjs ../platform/priv/static/images/home/next-key-shuffle.webp
//
// The seeds are fixed by their order, so every run draws the same cards. The
// page is bundled the way build.mjs bundles the still page, with changes to the
// card shader: the studio and the dither are left out, the foil, the face's
// shine and the glare are halved, and each pixel's alpha is how much of the
// card, its edge or its key covers it, so the cards come out cut out of their
// backdrop. Chromium draws on the computer's graphics chip. The frames are joined with libwebp's own
// tools, cwebp and webpmux, which must be installed.
import {execFile} from "node:child_process"
import {createHash} from "node:crypto"
import {mkdir, mkdtemp, readFile, rm, writeFile} from "node:fs/promises"
import {createServer} from "node:http"
import {tmpdir} from "node:os"
import {extname, join} from "node:path"
import {promisify} from "node:util"
import {build} from "esbuild"
import {chromium} from "playwright-core"

const run = promisify(execFile)
const [out] = process.argv.slice(2)
if (!out) throw new Error("name the WebP file to write")

const CARDS = 100
/** How long each card shows, in milliseconds: ten a second. */
const SHOWS = 100
/** The size each card is drawn at, then the part of it the homepage's card box
 * holds (the interim pass's own box) and the size that part is kept at. */
const SIZE = [1200, 1500]
const FRAME = {box: [55, 123, 999, 1255], size: [480, 603]}
/** libwebp's quality for each card's colour and for its outline. */
const QUALITY = ["-q", "50", "-alpha_q", "50", "-m", "6", "-sharp_yuv"]

/** The card shader, without the studio and with the card's coverage as alpha, toned down to the interim pass's shine. */
const CUTS = [
  ["var col = vec3f(0.010, 0.011, 0.014) + vec3f(0.02, 0.021, 0.025) * exp(-r2 * 0.9);", "var col = vec3f(0.0);"],
  ["col *= 1.0 - 0.8 * exp(-max(sdBox(screen - off, HALF * 0.97, 0.06), 0.0) * 16.0);", ""],
  // The still's dither is grain the animated picture would spend its bytes on.
  ["outc += vec3f((hash22(uv * res).x - 0.5) / 255.0);", ""],
  // Half the foil, the face's shine and the glare, as the interim pass reflects half the studio light.
  ["const FOIL = 0.72;", "const FOIL = 0.36;"],
  [
    "var shell = base * (0.1 + 0.9 * nl) + env * (0.03 + 0.3 * fres) * g + vec3f(pow(nh, mix(16.0, 260.0, g)) * g * 1.2);",
    "var shell = base * (0.1 + 0.9 * nl) + (env * (0.03 + 0.3 * fres) * g + vec3f(pow(nh, mix(16.0, 260.0, g)) * g * 1.2)) * 0.5;",
  ],
  ["* 0.04 * extC.a;", "* 0.02 * extC.a;"],
  ["return vec4f(outc, 1.0);", "return vec4f(outc, max(max(edgeIn, extC.a), k.a));"],
]
const cutOut = {
  name: "cut-out",
  setup(builder) {
    builder.onLoad({filter: /key_card[\\/]shader\.ts$/}, async ({path}) => {
      let source = await readFile(path, "utf8")
      for (const [from, to] of CUTS) {
        if (!source.includes(from)) throw new Error(`the card shader no longer has: ${from}`)
        source = source.replace(from, to)
      }
      return {contents: source, loader: "ts"}
    })
  },
}

const site = new URL("../platform/node_modules", import.meta.url).pathname
const dist = new URL("dist-shuffle/", import.meta.url).pathname
await mkdir(dist, {recursive: true})
await build({
  entryPoints: ["page/shuffle.ts", "page/still.css"],
  outdir: dist,
  bundle: true,
  format: "esm",
  target: "es2022",
  nodePaths: [site],
  loader: {".woff2": "file", ".woff": "file"},
  logLevel: "warning",
  plugins: [cutOut],
})
await writeFile(
  join(dist, "index.html"),
  '<!doctype html><html lang="en"><head><meta charset="utf-8"><link rel="stylesheet" href="still.css"><script type="module" src="shuffle.js"></script></head><body></body></html>',
)

const TYPES = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2", ".woff": "font/woff"}
const server = createServer(async (req, res) => {
  const name = req.url === "/" ? "index.html" : req.url.slice(1)
  try {
    const body = await readFile(join(dist, name))
    res.writeHead(200, {"content-type": TYPES[extname(name)] ?? "application/octet-stream"})
    res.end(body)
  } catch {
    res.writeHead(404)
    res.end()
  }
})
await new Promise(ready => server.listen(0, "127.0.0.1", ready))

// Seed n is sha256("keyfleet-shuffle-<n>"): fixed, and of no fleet's deck.
const cards = Array.from({length: CARDS}, (_, n) => ({seed: "0x" + createHash("sha256").update(`keyfleet-shuffle-${n}`).digest("hex")}))

const frames = await mkdtemp(join(tmpdir(), "keyfleet-shuffle-"))
const browser = await chromium.launch({args: ["--enable-unsafe-webgpu", "--enable-gpu", "--use-angle=metal", "--ignore-gpu-blocklist"]})
try {
  const page = await browser.newPage()
  await page.goto(`http://127.0.0.1:${server.address().port}/`)
  await page.waitForSelector("body[data-state=ready]", {state: "attached"})
  const mux = []
  // A few at a time, so one page never holds every picture at once.
  for (let from = 0; from < cards.length; from += 10) {
    const drawn = await page.evaluate(([batch, size, frame]) => window.shuffleCards(batch, size, frame), [cards.slice(from, from + 10), SIZE, FRAME])
    for (const [i, card] of drawn.entries()) {
      const name = join(frames, `card-${String(from + i).padStart(3, "0")}`)
      await writeFile(`${name}.png`, Buffer.from(card.split(",")[1], "base64"))
      await run("cwebp", ["-quiet", ...QUALITY, `${name}.png`, "-o", `${name}.webp`])
      mux.push("-frame", `${name}.webp`, `+${SHOWS}+0+0+0-b`)
    }
    console.log(`drew ${Math.min(from + 10, cards.length)} of ${cards.length}`)
  }
  await run("webpmux", [...mux, "-loop", "0", "-bgcolor", "0,0,0,0", "-o", out])
} finally {
  await browser.close()
  server.close()
  await rm(frames, {recursive: true})
}
