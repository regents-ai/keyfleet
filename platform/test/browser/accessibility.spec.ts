import AxeBuilder from "@axe-core/playwright"
import {expect, test, type Page} from "@playwright/test"
import {visit} from "./support/first_visit"

// Every main page a visitor reaches signed out, checked by axe against WCAG
// 2.0, 2.1 and 2.2 at levels A and AA, in the light and the dark theme, on a
// desktop screen and at a phone's 390px. A serious or critical violation
// fails the page; every violation, whatever its impact, is printed with the
// element it was found on, for the review in docs/launch-readiness.
//
// The site is as it launches (support/club_world.ts): Classic #1 is coming
// soon and shows no tabs, so the Regents Club's tabs stand for a fleet's
// tabs. axe sees what is drawn; what it can't see (focus order, what a screen
// reader says) is walked by hand in docs/launch-readiness/screen-reader-pass.md.

const club = "/app/fleets/regents_club"
const tags = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]

type Stop = {name: string; open: (page: Page) => Promise<void>}

const at = (name: string, path: string): Stop => ({name, open: page => visit(page, path)})

const stops: Stop[] = [
  at("homepage", "/"),
  at("Classic #1", "/classic/1"),
  at("Regents Club hall", club),
  at("Regents Club treasury", `${club}/treasury`),
  at("Regents Club proposals", `${club}/proposals`),
  at("Regents Club workspace", `${club}/workspace`),
  at("Regents Club Keys", `${club}?view=map`),
  at("Regents Club members", `${club}?view=members`),
  at("a Key", `${club}/keys/1`),
  at("a room", `${club}?room=general`),
  at("the polls", `${club}/polls`),
  at("About", "/about"),
  at("Opportunities", "/opportunities"),
]

const screens = [
  {name: "desktop", viewport: {width: 1280, height: 800}},
  {name: "phone", viewport: {width: 390, height: 844}},
]

for (const scheme of ["light", "dark"] as const) {
  for (const screen of screens) {
    for (const stop of stops) {
      test(`${stop.name}, ${scheme}, ${screen.name}`, async ({page}) => {
        await page.setViewportSize(screen.viewport)
        await page.context().addCookies([{name: "regent_theme", value: scheme, url: test.info().project.use.baseURL as string}])
        await stop.open(page)
        // What the page reads once connected is drawn, and the faces it
        // writes in are loaded, so the colours axe reads are the final ones.
        await page.waitForLoadState("networkidle")
        await page.evaluate(() => document.fonts.ready)

        const {violations} = await new AxeBuilder({page}).withTags(tags).analyze()
        const lines = violations.flatMap(violation =>
          violation.nodes.map(
            node => `[${violation.impact}] ${violation.id}: ${violation.help} at ${node.target.join(" ")}`,
          ),
        )
        for (const line of lines) console.log(`${stop.name}, ${scheme}, ${screen.name}: ${line}`)
        await test.info().attach("axe violations", {body: JSON.stringify(violations, null, 2), contentType: "application/json"})

        const blocking = lines.filter(line => line.startsWith("[serious]") || line.startsWith("[critical]"))
        expect(blocking, "serious or critical violations").toEqual([])
      })
    }
  }
}
