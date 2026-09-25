import {expect, test} from "@playwright/test"

// The harness boots one server with the default environment, where product surfaces are
// open, so this file holds the open state honest end to end. The closed state is proven
// against the same router and holding page in test/keyfleet_web/launch_gate_test.exs
// and test/keyfleet_web/controllers/holding_controller_test.exs, which flip the
// setting between requests.

test("the marketing page is served with product surfaces open", async ({page, request}) => {
  const response = await request.get("/")
  expect(response.status()).toBe(200)
  expect(response.headers()["cache-control"]).not.toContain("no-store")

  await page.goto("/")
  await expect(page.getByRole("heading", {name: "Your agent has tools. Now give it a crew.", level: 1})).toBeVisible()
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
