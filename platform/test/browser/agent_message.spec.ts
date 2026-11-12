import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// The Agent Message button on /agents opens its window at a desktop, a phone
// and the narrowest phone width: each of its three texts fits the screen and
// copies exactly what it shows, and Escape and the X close it, beside the
// page's shared confirm window, which stays shut. Signed in as
// "valid" (test/support/test_privy_verifier.ex), a person leaves a message
// from its form and sees the receipt, after an empty message is refused when
// the field is left. Each width's button and open window are attached to the
// test's results.
test.use({permissions: ["clipboard-read", "clipboard-write"]})

const sizes = [
  {width: 1280, height: 800},
  {width: 390, height: 844},
  {width: 320, height: 640},
]

const opener = (page: Page) => page.getByRole("button", {name: "Agent Message"})
const window = (page: Page) => page.getByRole("dialog", {name: "Agent Message"})

const fitsSideways = (page: Page) =>
  page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)

test("on /agents, an agent's texts fit and copy at every width", async ({page}, testInfo) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))

  for (const size of sizes) {
    await page.setViewportSize(size)
    await page.goto("/agents")
    await expect(window(page)).toBeHidden()
    await expect(opener(page)).toBeVisible()
    expect(await fitsSideways(page)).toBe(true)
    await testInfo.attach(`button-${size.width}`, {body: await opener(page).screenshot(), contentType: "image/png"})

    await opener(page).click()
    await expect(window(page)).toBeVisible()
    // The page's shared confirm window is there too, and stays shut.
    await expect(page.locator("#rg-confirm")).toBeAttached()
    await expect(page.locator("#rg-confirm")).toBeHidden()
    const texts = window(page).locator(".agent-message__text")
    await expect(texts).toHaveCount(3)
    for (const text of await texts.all()) {
      expect(await text.locator("pre").evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true)
    }
    const box = await window(page).boundingBox()
    expect(box && box.x >= 0 && box.x + box.width <= size.width).toBe(true)
    await expect(window(page)).toBeInViewport()
    await testInfo.attach(`window-${size.width}`, {body: await window(page).screenshot(), contentType: "image/png"})

    const cli = texts.first()
    await page.evaluate(() => navigator.clipboard.writeText(""))
    await cli.getByRole("button", {name: "Copy"}).click()
    const copied = await page.evaluate(() => navigator.clipboard.readText())
    expect(copied).toBe(await cli.locator("code").textContent())
    expect(copied).toContain("regents keyfleet messages leave agents")

    // Signed out, there is no form.
    await expect(window(page).locator("#agents-message-person-form")).toHaveCount(0)

    await page.keyboard.press("Escape")
    await expect(window(page)).toBeHidden()
    await opener(page).click()
    await expect(window(page)).toBeVisible()
    await window(page).getByRole("button", {name: "Close"}).click()
    await expect(window(page)).toBeHidden()
  }

  expect(errors).toEqual([])
})

test("a signed-in person leaves a message from the window and sees its receipt", async ({page}) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()

  await page.setViewportSize({width: 390, height: 844})
  await page.goto("/agents")
  await opener(page).click()

  const form = window(page).locator("#agents-message-person-form")
  await expect(page.locator(".phx-connected:has(#agents-message-person-form)").first()).toBeAttached()
  const body = form.getByRole("textbox", {name: "Message", exact: true})
  await body.fill("x")
  await body.fill("")
  await form.getByRole("textbox", {name: "Reply to"}).focus()
  await expect(body).toHaveAttribute("aria-invalid", "true")

  await body.fill("The Agents page lists an old harness.")
  await form.getByRole("textbox", {name: "Reply to"}).fill("walk@example.com")
  await form.getByRole("button", {name: "Send"}).click()
  const receipt = window(page).locator("#agents-message-person-receipt")
  await expect(receipt).toBeVisible()
  await expect(receipt.locator("code")).toHaveText(/^[0-9a-f-]{36}$/)
  await expect(body).toHaveValue("")
  await expect(window(page)).toBeVisible()
  expect(errors).toEqual([])
})
