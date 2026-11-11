// Draws the share pictures from card.html in headless Chromium:
//
//   priv/static/images/keyfleet-share.png   the site's picture
//   priv/share/<fleet_id>.png               each fleet's picture, without its figures
//   priv/share/glyphs-<style>.png           the characters the server sets figures in
//   priv/share/layout.json                  where the server puts them, and
//                                           each fleet's name and labels
//
// The server (KeyfleetWeb.ShareCard) adds each fleet's figures, its latest
// Key's name and that Key's card to its picture when the picture is asked for.
//
// Run from platform/ after `mix deps.get` and `npm ci`:
//   node scripts/share-cards/render.mjs
import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const platform = join(here, "..", "..");
const share = join(platform, "priv", "share");
const page_url = pathToFileURL(join(here, "card.html"));

// The fleets with a picture of their own, as their pages name them. `keys`
// is the line under the Keys figure, and `key` the line above the Key's name.
const fleets = [
  { id: "fleet_tech_classic", name: "Classic #1", keys: "Keys sold", key: "Last Key sold" },
  { id: "regents_club", name: "Regents Club", keys: "Keys", key: "Last Key to change hands" },
];

// The characters each style can set: the Keys in `value`, the treasury's
// amounts, one to a line, in `amount`, and Key names in `name`.
const glyphs = {
  value: "0123456789,/ ",
  amount: "0123456789,. ACDEGHNRSTU",
  name: "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ—",
};

// The empty space drawn around each character, so a character whose ink
// reaches past its width keeps it.
const pad = 8;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });

const open = async (query) => {
  const url = new URL(page_url);
  url.search = new URLSearchParams(query).toString();
  await page.goto(url.href);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => [...document.images].every((img) => img.complete));
};

mkdirSync(share, { recursive: true });

await open({ card: "home" });
await page.screenshot({ path: join(platform, "priv", "static", "images", "keyfleet-share.png") });

const layout = {
  slots: null,
  glyphs: {},
  fleets: Object.fromEntries(fleets.map(({ id, name, keys, key }) => [id, { name, keys, key }])),
};

for (const fleet of fleets) {
  await open({ card: "fleet", name: fleet.name, keys: fleet.keys, key: fleet.key });
  await page.screenshot({ path: join(share, `${fleet.id}.png`) });

  // Every fleet's picture has its slots in the same places.
  layout.slots = await page.evaluate(() =>
    Object.fromEntries(
      [...document.querySelectorAll("[data-slot]")].map((el) => {
        const { x, y, width, height } = el.getBoundingClientRect();
        return [el.dataset.slot, { x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) }];
      }),
    ),
  );
}

for (const [style, characters] of Object.entries(glyphs)) {
  await page.setViewportSize({ width: 4000, height: 200 });
  await open({ card: "glyphs", style, characters });
  await page.addStyleTag({ content: `.glyphs { gap: ${2 * pad}px; padding: 0 ${pad}px; }` });

  const { cells, height } = await page.evaluate(() => {
    const spans = [...document.querySelectorAll(".glyphs span")];
    return {
      height: Math.ceil(spans[0].getBoundingClientRect().height),
      cells: spans.map((span) => {
        const { x, width } = span.getBoundingClientRect();
        return [span.textContent, x, width];
      }),
    };
  });

  const last = cells.at(-1);
  const width = Math.ceil(last[1] + last[2] + pad);
  await page.screenshot({
    path: join(share, `glyphs-${style}.png`),
    clip: { x: 0, y: 0, width, height },
    omitBackground: true,
  });

  // Each character's cell in the strip, and how far it moves the pen.
  layout.glyphs[style] = {
    height,
    pad,
    characters: Object.fromEntries(
      cells.map(([character, x, advance]) => [character, { x: Math.round(x) - pad, advance: Math.round(advance * 100) / 100 }]),
    ),
  };
  await page.setViewportSize({ width: 1200, height: 630 });
}

writeFileSync(join(share, "layout.json"), JSON.stringify(layout, null, 2) + "\n");
await browser.close();
