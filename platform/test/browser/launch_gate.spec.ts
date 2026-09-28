import {expect, test, type Page} from "@playwright/test"

// The harness boots one server with the default environment, where product surfaces are
// open, so this file holds the open state honest end to end, and the early-access page,
// which is the same page in either state. The closed state is proven against the same
// endpoint in test/keyfleet_web/launch_gate_test.exs, which flips the setting between
// requests, and in the browser by content_security_policy.spec.ts, which flips it on its
// own server.

test("the marketing page is served with product surfaces open", async ({page, request}) => {
  const response = await request.get("/")
  expect(response.status()).toBe(200)
  expect(response.headers()["cache-control"]).not.toContain("no-store")

  await page.goto("/")
  await expect(page.getByRole("heading", {name: "No boss. No job queue. Just a crew that runs itself.", level: 1})).toBeVisible()
})

test("product routes render the shell while surfaces are open", async ({page, request}) => {
  for (const route of ["/app/fleets/fibonacci_syndicate", "/account"]) {
    const response = await request.get(route)
    expect(response.status()).toBe(200)
    expect(response.headers()["retry-after"]).toBeUndefined()

    await page.goto(route)
    await expect(page.locator("#app-shell")).toBeVisible()
  }
})

test("the health check stays plain and open", async ({request}) => {
  const response = await request.get("/healthz")
  expect(response.status()).toBe(200)
  expect(await response.text()).toBe("ok")
})

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
  // An address the form keeps is left by content_security_policy.spec.ts, whose
  // server never commits; this server's database is the ExUnit suite's.
  test(`the early-access page fits ${viewport.width}px and refuses an unreadable address, with no scripts and nothing of sign-in`, async ({page}) => {
    await page.setViewportSize(viewport)
    const {requested, sideways} = await openEarly(page)

    expect(sideways).toBe(false)
    expect(requested.filter(url => /privy/i.test(url))).toEqual([])
    expect(requested.filter(url => new URL(url).pathname.endsWith(".js"))).toEqual([])
    await expect(page.getByRole("heading", {name: "No boss. No job queue. Just a crew that runs itself.", level: 1})).toBeVisible()

    const email = page.getByLabel("Email")
    await email.fill("not an address")
    await page.getByRole("button", {name: "Tell me when it opens"}).click()
    await expect(page.getByText("That doesn't look like an email address.")).toBeVisible()
    await expect(email).toHaveValue("not an address")
    expect(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)).toBe(false)
  })
}
