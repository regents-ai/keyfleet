import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey, setSurfaces} from "./support/fleet_chain"

// Every page is served under a content security policy
// (lib/keyfleet_web/content_security_policy.ex). Whatever a policy leaves out
// is refused quietly, so each page here loads while the browser's refusals are
// collected, and there must be none. The key page needs a sold key, so this
// runs with the chain.
const fleet = "fibonacci_syndicate"
const me = "0x1111111111111111111111111111111111111111"

// Collects every refusal: the page's `securitypolicyviolation` events and the
// browser's "Refused to" console lines.
async function watchRefusals(page: Page): Promise<string[]> {
  const refusals: string[] = []
  await page.exposeFunction("__keyfleetRefused", (line: string) => refusals.push(line))
  await page.addInitScript(() => {
    document.addEventListener("securitypolicyviolation", event => {
      const report = (window as unknown as {__keyfleetRefused: (line: string) => void}).__keyfleetRefused
      void report(`${event.effectiveDirective} refused ${event.blockedURI}`)
    })
  })
  page.on("console", message => {
    if (message.text().includes("Refused to")) refusals.push(message.text())
  })
  return refusals
}

async function open(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await page.waitForLoadState("networkidle")
}

test.beforeAll(() => {
  prepareFleet(fleet)
})

test("the main pages load with nothing refused", async ({page}) => {
  const key = sellKey(fleet, me)
  const refusals = await watchRefusals(page)
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()

  for (const path of [
    "/",
    `/app/fleets/${fleet}`,
    `/app/fleets/${fleet}/proposals`,
    `/app/keys/${fleet}/${key}`,
    "/account",
  ]) {
    await open(page, path)
    expect(refusals, path).toEqual([])
  }
})

test("opening sign-in starts Privy with nothing refused", async ({page}) => {
  const refusals = await watchRefusals(page)
  await open(page, "/account")

  // Privy stops at the test server's placeholder app id before loading
  // anything. A well-formed id, which Privy's API then turns down, takes it as
  // far as it goes before a real app's window opens: its styles, its wallet
  // list and its API.
  await page
    .locator("meta[name='privy-app-id']")
    .evaluate(meta => meta.setAttribute("content", "clp0000000000000000000000"))
  let privyAsked = false
  page.on("request", request => {
    if (request.url().startsWith("https://auth.privy.io/")) privyAsked = true
  })
  await page.locator("#account-control [data-account-target=sign-in]").click()
  await expect.poll(() => privyAsked || refusals.length > 0).toBe(true)
  await page.waitForLoadState("networkidle")

  expect(refusals).toEqual([])
  expect(privyAsked).toBe(true)
})

test("reading pages load with nothing refused", async ({page}) => {
  const refusals = await watchRefusals(page)

  for (const path of ["/docs", "/opportunities"]) {
    await page.goto(path)
    await page.waitForLoadState("networkidle")
    expect(refusals, path).toEqual([])
  }
})

test("the closed page is styled with nothing refused", async ({page}) => {
  const refusals = await watchRefusals(page)
  setSurfaces(false)

  try {
    const response = await page.goto(`/app/fleets/${fleet}`)
    expect(response?.status()).toBe(503)
    await expect(page.getByRole("heading", {name: "Not open yet", level: 1})).toBeVisible()
    await page.waitForLoadState("networkidle")

    // The site's stylesheet applied: the button to the homepage is drawn as one.
    await expect(page.locator("main a.rg-button")).not.toHaveCSS("display", "inline")
    expect(refusals).toEqual([])
  } finally {
    setSurfaces(true)
  }
})
