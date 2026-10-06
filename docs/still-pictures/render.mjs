// Renders each key in keys.json as its opened card and saves it to <out>/art/<table hash>/<slot>/<key>.png,
// the path the site's key metadata names, plus <out>/report.json with each picture's sha256 and traits.
// Usage: node render.mjs <Key Lab page .html> <out> <slot> <table hash>
// CHANNEL=chromium uses the computer's graphics chip; without it Chromium draws on the CPU (SwiftShader).
import { chromium } from "../../platform/node_modules/playwright/index.mjs";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
const [page_path, outDir, slot, hash] = process.argv.slice(2);
const keys = JSON.parse(readFileSync(new URL("keys.json", import.meta.url), "utf8"));
const browser = await chromium.launch({ headless: true, channel: process.env.CHANNEL || undefined, args: ["--enable-unsafe-webgpu"] });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
const errors = [];
page.on("pageerror", e => errors.push(e.message));
page.on("console", m => { if (m.type() === "error") errors.push(m.text()); });
const report = [];
for (const { key, seed } of keys) {
  // A change of the link's # part alone does not reload the page, so each key starts from a blank page.
  await page.goto("about:blank");
  await page.goto(`file://${resolve(page_path)}#seed=${seed}&key=${key}&open`);
  await page.waitForSelector(".stage.ready", { timeout: 60000 });
  await page.waitForFunction(() => document.querySelector("#unlockBtn").textContent === "Lock");
  await page.waitForTimeout(2500);
  const shot = await page.evaluate(() => {
    const c = document.querySelector("#cardCanvas");
    const traits = Object.fromEntries([...document.querySelectorAll("#rows select")].map(s => [s.dataset.t, s.value]));
    return { png: c.toDataURL("image/png"), w: c.width, h: c.height, traits };
  });
  const bytes = Buffer.from(shot.png.split(",")[1], "base64");
  const dir = `${outDir}/art/${hash}/${slot}`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/${key}.png`, bytes);
  report.push({ key, seed, size: [shot.w, shot.h], sha256: createHash("sha256").update(bytes).digest("hex"), traits: shot.traits });
}
await browser.close();
writeFileSync(`${outDir}/report.json`, JSON.stringify({ errors, report }, null, 2));
console.log(JSON.stringify({ errors, report: report.map(r => [r.key, r.sha256.slice(0, 16), r.traits.form, r.traits.skin]) }));
