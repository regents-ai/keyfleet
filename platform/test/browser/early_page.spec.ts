import {expect, test, type Page} from "@playwright/test"
import {rollerOnly} from "./support/early"
import {setSurfaces} from "./support/fleet_chain"

// The early-access page is open only while the site is closed; once it opens,
// /early sends visitors to the homepage. So this runs with the chain's server,
// which can close the site.
test.beforeEach(() => setSurfaces(false))
test.afterEach(() => setSurfaces(true))

// Every request the page makes, and whether anything on it is wider than the window.
async function openEarly(page: Page) {
  const requested: string[] = []
  page.on("request", request => requested.push(request.url()))
  await page.goto("/early")
  await page.waitForLoadState("networkidle")
  const sideways = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)
  return {requested, sideways}
}

for (const viewport of [{width: 375, height: 812}, {width: 1440, height: 900}]) {
  test(`the early-access page fits ${viewport.width}px and refuses an unreadable address, with only the key roller and nothing of sign-in`, async ({page}) => {
    await page.setViewportSize(viewport)
    const {requested, sideways} = await openEarly(page)

    expect(sideways).toBe(false)
    expect(requested.filter(url => /privy/i.test(url))).toEqual([])
    expect(rollerOnly(requested)).toBe(true)
    await expect(page.getByRole("heading", {name: "Attach your personal agent to a crew that runs itself.", level: 1})).toBeVisible()
    await expect(page.getByRole("link", {name: "Follow on X"})).toHaveAttribute("href", "https://x.com/regents_sh")
    await expect(page.getByRole("link", {name: "Follow on X"})).toBeVisible()
    await expect(page.getByRole("heading", {name: "Tech stack", level: 2})).toBeVisible()
    await expect(page.locator("#early-tech-stack li")).toHaveCount(4)

    const email = page.getByLabel("Email")
    await email.fill("not an address")
    await page.getByRole("button", {name: "Tell me when it opens"}).click()
    await expect(page.getByText("That doesn't look like an email address.")).toBeVisible()
    await expect(email).toHaveValue("not an address")
    expect(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)).toBe(false)
  })
}
