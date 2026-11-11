import {execFileSync} from "node:child_process"
import {readdirSync} from "node:fs"
import {expect, test, type Page} from "@playwright/test"
import {forget, leftovers, moved, pageChangeMoved, pressRapidly, watchMotion} from "./support/motion"

// However fast a reader presses, every move ends at rest: a move begun over
// another's half-way frame still hands its element back to the stylesheet
// with no inline transform or opacity left. A page changed from the keyboard,
// or for a reader who asked for less motion, shows at once every time.

const fleetPath = "/classic/1"

async function openFleet(page: Page) {
  await watchMotion(page)
  await page.goto(fleetPath)
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await forget(page)
}

// Moves settle within half a second; this waits well past the last one.
const settle = (page: Page) => page.waitForTimeout(1_000)

// The shell keeps one live session across pages, so a link to another page
// patches the one it is on, as the sidebar's links do.
async function patchTo(page: Page, path: string, by: "pointer" | "keyboard" = "pointer") {
  await page.evaluate(destination => {
    document.querySelector("#patch-probe")?.remove()
    const link = document.createElement("a")
    link.id = "patch-probe"
    link.href = destination
    link.textContent = destination
    link.dataset.phxLink = "patch"
    link.dataset.phxLinkState = "push"
    document.querySelector("#route-content")?.append(link)
  }, path)
  if (by === "pointer") await page.locator("#patch-probe").click()
  else await page.locator("#patch-probe").press("Enter")
  await expect(page).toHaveURL(new RegExp(`${path}$`))
}

// The motion kit on its own, built with the esbuild the asset build installs,
// so a blank page can play moves on elements it makes.
function motionKit() {
  const esbuild = readdirSync("_build").find(name => name.startsWith("esbuild-"))!
  return execFileSync(`_build/${esbuild}`, [
    "assets/js/hooks/motion/shared.ts",
    "--bundle",
    "--format=iife",
    "--global-name=motionKit",
  ]).toString()
}

test("a move played again and again over its own half-way frame ends at rest", async ({page}) => {
  await page.addScriptTag({content: motionKit()})

  const ends = await page.evaluate(async () => {
    const {play} = (window as unknown as {motionKit: typeof import("../../assets/js/hooks/motion/shared")}).motionKit
    const wait = (ms: number) => new Promise(done => setTimeout(done, ms))
    const moves = {
      "from and to": {y: [-6, 0], scale: [0.9, 1], opacity: [0, 1], duration: 280},
      "from only": {y: {from: 16}, opacity: {from: 0}, duration: 280},
    }
    const ends: Record<string, {midway: string | null; end: string | null}> = {}
    for (const [name, move] of Object.entries(moves)) {
      const el = document.body.appendChild(document.createElement("div"))
      let midway: string | null = null
      for (let press = 0; press < 5; press++) {
        play(el, move)
        await wait(70)
        midway ??= el.getAttribute("style")
      }
      await wait(1_000)
      ends[name] = {midway, end: el.getAttribute("style")}
    }
    return ends
  })

  for (const [name, {midway, end}] of Object.entries(ends)) {
    expect(midway, `${name} was moving`).toMatch(/transform|opacity/)
    expect(end, `${name} at rest`).toBeNull()
  }
})

test("a phone's menu button pressed again and again mid-move leaves the button and its drawer at rest", async ({
  page,
}) => {
  await page.setViewportSize({width: 390, height: 844})
  await openFleet(page)

  await pressRapidly(page, "#mobile-menu-button")
  await settle(page)

  expect(await moved(page, "#mobile-menu-button")).toBe(true)
  expect(await moved(page, "#shell-sidebar")).toBe(true)
  expect(await leftovers(page)).toEqual([])
})

test("a refused copy shakes over the press's squish and still ends at rest", async ({page}) => {
  await page.addInitScript(() => {
    navigator.clipboard.writeText = () => Promise.reject(new DOMException("Refused", "NotAllowedError"))
  })
  await openFleet(page)
  await page.locator("#shell-regents-crown > summary").hover()
  await expect(page.locator("#shell-regents-crown-copy")).toBeVisible()
  await forget(page)

  await pressRapidly(page, "#shell-regents-crown-copy")
  await settle(page)

  expect(await moved(page, "#shell-regents-crown-copy")).toBe(true)
  expect(await leftovers(page)).toEqual([])
})

test("a pointer's page change moves the page arriving", async ({page}) => {
  await openFleet(page)

  await patchTo(page, "/account")

  await expect.poll(() => pageChangeMoved(page)).toBe(true)
})

test("a keyboard's page change shows the page arriving at once", async ({page}) => {
  await openFleet(page)

  for (const path of ["/account", fleetPath]) {
    await patchTo(page, path, "keyboard")
    await settle(page)
    expect(await pageChangeMoved(page), `the change to ${path}`).toBe(false)
  }
})

test("a reader who asked for less motion sees no page change move, however many pages they visit", async ({
  browser,
}) => {
  const context = await browser.newContext({reducedMotion: "reduce"})
  const page = await context.newPage()
  await openFleet(page)

  for (const path of ["/account", fleetPath, "/account", fleetPath]) {
    await patchTo(page, path)
    await settle(page)
    expect(await pageChangeMoved(page), `the change to ${path}`).toBe(false)
  }
  await context.close()
})
