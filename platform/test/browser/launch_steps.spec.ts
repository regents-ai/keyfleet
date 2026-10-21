import {expect, test, type Page} from "@playwright/test"

// Each step a visitor takes into Keyfleet is reported once as it happens
// (assets/js/launch_steps.ts): the homepage opened, each way in pressed, and a
// setup line copied, with the agent it is for. A browser a program drives
// reports nothing, so these pages are told they are a visitor's.

test.use({permissions: ["clipboard-read", "clipboard-write"]})

test.beforeEach(async ({page}) => {
  await page.addInitScript(() => Object.defineProperty(navigator, "webdriver", {get: () => false}))
})

// Every report the page sends, in order, with what the site answered.
function reports(page: Page) {
  const sent: unknown[] = []
  const answers: number[] = []
  page.on("request", request => {
    if (request.method() === "POST" && new URL(request.url()).pathname === "/steps")
      sent.push(JSON.parse(request.postData() ?? "null"))
  })
  page.on("response", response => {
    if (new URL(response.url()).pathname === "/steps") answers.push(response.status())
  })
  return {sent, answers}
}

async function connected(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

test("the homepage and each way in are counted once", async ({page}) => {
  const {sent, answers} = reports(page)

  await page.goto("/")
  await connected(page)
  await expect.poll(() => sent).toEqual([{step: "home"}])

  // A page that loses its connection and reconnects has not been opened again.
  await page.evaluate(() => {
    const socket = (window as unknown as {liveSocket: {disconnect(): void; connect(): void}}).liveSocket
    socket.disconnect()
    socket.connect()
  })
  await connected(page)

  await page.locator("#home-watch").click()
  await expect(page).toHaveURL(/\/classic\/1$/)
  await connected(page)
  await expect.poll(() => sent).toEqual([{step: "home"}, {step: "watch"}])

  // Coming back to the homepage is another arrival.
  await page.goBack()
  await expect(page).toHaveURL(/\/$/)
  await connected(page)
  await page.locator("#home-connect").click()
  await expect(page).toHaveURL(/\/connect$/)
  await expect
    .poll(() => sent)
    .toEqual([{step: "home"}, {step: "watch"}, {step: "home"}, {step: "connect"}])
  await expect.poll(() => answers).toEqual([204, 204, 204, 204])
})

test("a copied setup line is counted with the agent it is for", async ({page}) => {
  const {sent, answers} = reports(page)

  await page.goto("/")
  await connected(page)
  await page.locator("#home-instruction-copy").click()
  await expect(page.locator("#home-instruction-copy")).toHaveAttribute("data-copy-state", "copied")

  await page.goto("/connect?agent=hermes")
  await connected(page)
  await page.locator("#connect-copy").click()
  await expect(page.locator("#connect-copy")).toHaveAttribute("data-copy-state", "copied")

  await expect
    .poll(() => sent)
    .toEqual([{step: "home"}, {step: "copy", agent: "any"}, {step: "copy", agent: "hermes"}])
  await expect.poll(() => answers).toEqual([204, 204, 204])
})

test("a browser a program drives reports nothing", async ({browser}) => {
  const page = await browser.newPage()
  const {sent} = reports(page)

  await page.goto("/")
  await connected(page)
  await page.locator("#home-watch").click()
  await expect(page).toHaveURL(/\/classic\/1$/)
  // Time for a report that would have been sent to have left.
  await page.waitForTimeout(500)
  expect(sent).toEqual([])
  await page.close()
})
