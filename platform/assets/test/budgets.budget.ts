import {readFileSync} from "node:fs"
import {gzipSync} from "node:zlib"

import {describe, expect, it} from "vitest"

const builtAsset = (name: string) => readFileSync(new URL(`../../priv/static/assets/js/${name}`, import.meta.url))

// The files a built script imports, named as esbuild writes them.
const importsOf = (name: string) =>
  [...builtAsset(name).toString().matchAll(/(?:import\(|from |import )"\.\/([\w-]+\.js)"/g)].map(match => match[1])

describe("built asset budgets", () => {
  it("keeps JavaScript at or below 175 KiB gzip", () => {
    expect(gzipSync(builtAsset("app.js")).byteLength).toBeLessThanOrEqual(175 * 1024)
  })

  it("keeps CSS at or below 60 KiB gzip", () => {
    expect(gzipSync(builtAsset("app.css")).byteLength).toBeLessThanOrEqual(60 * 1024)
  })

  // Found through app.js, because older builds leave their hashed files behind.
  it("keeps the key map at or below 15 KiB gzip, with everything it imports", () => {
    const [stage] = importsOf("app.js").filter(name => name.startsWith("key_map_stage-"))
    expect(stage).toBeDefined()
    const files = [stage, ...importsOf(stage)]
    const bytes = files.reduce((total, name) => total + gzipSync(builtAsset(name)).byteLength, 0)
    expect(bytes).toBeLessThanOrEqual(15 * 1024)
  })
})
