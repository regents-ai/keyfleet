// Bundles the drawing page into dist/: the card code from the site's own
// platform/assets/js/key_card, with its packages and fonts from platform/node_modules,
// so the site and the pictures draw with the same code and the same versions.
import {copyFile, mkdir} from "node:fs/promises"
import {build} from "esbuild"

const site = new URL("../platform/node_modules", import.meta.url).pathname

await mkdir("dist", {recursive: true})
await build({
  entryPoints: ["page/still.ts", "page/still.css"],
  outdir: "dist",
  bundle: true,
  format: "esm",
  target: "es2022",
  nodePaths: [site],
  loader: {".woff2": "file", ".woff": "file"},
  logLevel: "warning",
})
await copyFile("page/still.html", "dist/still.html")
