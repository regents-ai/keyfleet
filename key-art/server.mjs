// The key-art service: draws one key's card as a PNG for the site's picture job.
// POST /draw with {"seed", "top_line", "table"} answers the picture (200, image/png), why the
// body is unreadable (400, JSON) or why it could not be drawn (422, JSON). GET /healthz answers 200 once the browser is up
// and 503 while it starts. Every
// other GET serves the drawing page in dist/, which this server's own browser opens.
import {createServer} from "node:http"
import {readFile} from "node:fs/promises"
import {extname} from "node:path"
import {chromium} from "playwright-core"

const PORT = Number(process.env.PORT ?? 8080)
const DIST = new URL("dist/", import.meta.url)
const TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".woff2": "font/woff2", ".woff": "font/woff"}
const MAX_BODY = 4096
const DRAW_TIMEOUT = 120_000

// WebGPU on the CPU: the machine has no graphics chip, so Chromium draws with SwiftShader.
// The browser starts while the server already listens: a sleeping machine is woken by a
// draw, and Fly's proxy gives up on a machine that takes longer than the browser's start
// to accept a connection. The waking draw waits for the browser instead.
let browserUp = false
const browser = chromium
  .launch({
    args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-vulkan=swiftshader", "--use-webgpu-adapter=swiftshader", "--disable-vulkan-surface"],
  })
  .then(started => {
    browserUp = true
    // A browser that dies takes the service with it; the machine restarts it.
    started.on("disconnected", () => process.exit(1))
    return started
  })
browser.catch(error => {
  console.error("key-art could not start its browser:", error)
  process.exit(1)
})

const reply = (res, status, type, body) => {
  res.writeHead(status, {"content-type": type, "content-length": Buffer.byteLength(body)})
  res.end(body)
}
const replyJson = (res, status, value) => reply(res, status, "application/json", JSON.stringify(value))

async function readJson(req) {
  let size = 0
  const chunks = []
  for await (const chunk of req) {
    size += chunk.length
    if (size > MAX_BODY) return null
    chunks.push(chunk)
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"))
  } catch {
    return null
  }
}

// Each card is drawn on a fresh page, so the same key always gives the same bytes.
async function drawCard({seed, top_line, table}) {
  const page = await (await browser).newPage()
  try {
    const asked = new URLSearchParams({seed, top: top_line, table})
    await page.goto(`http://127.0.0.1:${PORT}/still.html#${asked}`)
    await page.waitForSelector("body[data-state]", {state: "attached", timeout: DRAW_TIMEOUT})
    return await page.evaluate(() => {
      const {state, reason} = document.body.dataset
      return state === "done" ? {png: window.stillPicture} : {reason}
    })
  } finally {
    await page.close()
  }
}

async function serveFile(res, path) {
  const name = path === "/" ? "still.html" : path.slice(1)
  if (!/^[a-z0-9._-]+$/i.test(name) || !TYPES[extname(name)]) return replyJson(res, 404, {error: "not found"})
  try {
    reply(res, 200, TYPES[extname(name)], await readFile(new URL(name, DIST)))
  } catch {
    replyJson(res, 404, {error: "not found"})
  }
}

const server = createServer(async (req, res) => {
  try {
    const {pathname} = new URL(req.url, "http://key-art")
    if (req.method === "GET" && pathname === "/healthz")
      return browserUp ? replyJson(res, 200, {ok: true}) : replyJson(res, 503, {error: "browser starting"})
    if (req.method === "GET") return await serveFile(res, pathname)
    if (req.method !== "POST" || pathname !== "/draw") return replyJson(res, 404, {error: "not found"})

    const asked = await readJson(req)
    if (!asked || ![asked.seed, asked.top_line, asked.table].every(v => typeof v === "string"))
      return replyJson(res, 400, {error: "send seed, top_line and table as strings"})
    const {png, reason} = await drawCard(asked)
    if (!png) return replyJson(res, 422, {error: reason})
    const bytes = Buffer.from(png.slice(png.indexOf(",") + 1), "base64")
    res.writeHead(200, {"content-type": "image/png", "content-length": bytes.length})
    res.end(bytes)
  } catch (error) {
    // A client that hung up mid-request is owed no answer.
    if (!res.destroyed) replyJson(res, 500, {error: String(error)})
  }
})

server.listen(PORT, "::", () => console.log(`key-art listening on ${PORT}`))
