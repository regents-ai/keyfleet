import {expect, type Locator, type Page} from "@playwright/test"

// What a person notices on any page, whatever they came for: it fits the
// screen, its controls are big enough for a finger, it raises no error, and
// it stays live.

/** Every error the page logs or throws from now on, as text. */
export function watchErrors(page: Page): string[] {
  const errors: string[] = []
  page.on("console", message => {
    if (message.type() === "error") errors.push(message.text())
  })
  page.on("pageerror", error => errors.push(error.message))
  return errors
}

/** Opens `path` and waits until its live connection is up. */
export async function visit(page: Page, path: string) {
  await page.goto(path)
  await expectConnected(page)
}

/** The page's live connection is up: its root carries `phx-connected`. */
export async function expectConnected(page: Page) {
  await expect(page.locator("[data-phx-main]"), "the page is connected").toHaveClass(/\bphx-connected\b/)
}

/**
 * Nothing scrolls sideways: neither the page nor the shell's scrolling pane is
 * wider than the screen. A row meant to scroll sideways inside the page, such
 * as a holder's Key cards, scrolls within its own box and is not counted.
 */
export async function expectNoSidewaysScroll(page: Page) {
  const widths = await page.evaluate(() =>
    [document.documentElement, document.querySelector("#app-shell-scroller")]
      .filter(element => element !== null)
      .map(element => ({name: element!.id || "page", scroll: element!.scrollWidth, width: element!.clientWidth})),
  )
  for (const {name, scroll, width} of widths) {
    expect(scroll, `the ${name} is ${scroll}px wide on a ${width}px screen`).toBeLessThanOrEqual(width)
  }
}

/** `thing` is on the first screen, top to bottom, with nothing scrolled. */
export async function expectOnFirstScreen(page: Page, thing: Locator, what: string) {
  await expect(thing, `${what} shows`).toBeVisible()
  const box = (await thing.boundingBox())!
  const screen = await page.evaluate(() => window.innerHeight)
  expect(box.y + box.height, `${what} ends inside the first ${screen}px of the screen`).toBeLessThanOrEqual(screen)
}

/**
 * How far below the first screen `thing` ends, in pixels, or 0 when it is on
 * it. For a measurement the run reports rather than one it fails on.
 */
export async function belowFirstScreen(page: Page, thing: Locator): Promise<number> {
  const box = (await thing.boundingBox())!
  const screen = await page.evaluate(() => window.innerHeight)
  return Math.max(0, Math.ceil(box.y + box.height - screen))
}

/**
 * Every control drawn on the page that is too small to press: under 44px on
 * a touch screen, the size a fingertip needs, and under 24px with a mouse
 * (WCAG 2.2, 2.5.8). Buttons, fields and icon-only links must be that tall
 * and that wide; a link of words standing on its own must be that tall, and
 * its words make it as wide as they are. A link inside a sentence is part of
 * the text and not counted, nor is anything out of sight or hidden from
 * assistive technology.
 */
export async function expectTapTargets(page: Page) {
  const small = await page.evaluate(() => {
    const touch = matchMedia("(pointer: coarse)").matches
    const least = touch ? 44 : 24
    const controls = document.querySelectorAll<HTMLElement>(
      "a[href], button, select, textarea, summary, [role=button], input:not([type=hidden])",
    )
    const found: string[] = []
    for (const control of controls) {
      if (control.closest("[inert], [aria-hidden=true], .visually-hidden")) continue
      // A radio button or a box to tick is pressed by its label.
      const target = control.matches("input[type=radio], input[type=checkbox]")
        ? (control.closest("label") ?? control)
        : control
      const box = target.getBoundingClientRect()
      const style = getComputedStyle(target)
      if (box.width === 0 || box.height === 0 || style.visibility === "hidden") continue
      if (box.bottom <= 0 || box.right <= 0 || box.left >= window.innerWidth) continue
      const link = target.tagName === "A" && !target.classList.contains("rg-button")
      if (link && style.display === "inline") continue
      const iconOnly = link && (target.textContent ?? "").trim() === ""
      const short = box.height < least - 0.5
      const narrow = (!link || iconOnly) && box.width < least - 0.5
      if (short || narrow) {
        const name = target.getAttribute("aria-label") || (target.textContent ?? "").trim().slice(0, 40)
        found.push(`${target.tagName.toLowerCase()}${target.id ? `#${target.id}` : ""} "${name}" is ${Math.round(box.width)}x${Math.round(box.height)}px`)
      }
    }
    return {least, found}
  })
  expect(small.found, `controls under ${small.least}px`).toEqual([])
}

/** The checks every step of a flow ends with. */
export async function expectComfortable(page: Page, errors: string[]) {
  await expectConnected(page)
  await expectNoSidewaysScroll(page)
  await expectTapTargets(page)
  expect(errors, "errors the page raised").toEqual([])
}
