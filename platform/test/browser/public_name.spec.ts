import {expect, test, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"

// Invariants covered, at 1280 and 390 wide, signed in:
// - Save on the Account page's Public Display Name keeps the name with the page's
//   own sign-in, its session cookie and forms token, and says so beside Save
//   without moving it
// - the name at the top right shows the saved name at once, and the Account page
//   shows it again after a reload

async function signIn(page: Page) {
  const auth = await installAuthenticatedPrivy(page, "valid")
  await auth.establishLocalSession()
}

async function openAccount(page: Page) {
  await page.goto("/account")
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
}

for (const width of [1280, 390]) {
  test.describe(`${width}px wide`, () => {
    test.use({viewport: {width, height: 900}})

    test("Save keeps the name with the page's own sign-in", async ({page}) => {
      const saved = `Walk ${width} ${Date.now()}`
      await signIn(page)
      await openAccount(page)

      const form = page.locator("#account-public-name")
      const name = form.getByRole("textbox", {name: "Public Display Name"})
      const save = form.getByRole("button", {name: "Save"})
      await expect(name).toBeVisible()
      await save.scrollIntoViewIfNeeded()
      // Where Save sits in the form, and how tall the form is, wherever the page scrolls.
      const place = () =>
        Promise.all([form.boundingBox(), save.boundingBox()]).then(([f, b]) => ({
          x: b!.x - f!.x,
          y: b!.y - f!.y,
          height: f!.height,
        }))
      const before = await place()

      await name.fill(saved)
      const change = page.waitForResponse(
        response =>
          new URL(response.url()).pathname === "/api/v1/profile" &&
          response.request().method() === "PATCH",
      )
      await save.click()
      const answer = await change
      expect(answer.status()).toBe(200)
      expect(answer.request().headers()["x-csrf-token"]).toBeTruthy()
      await expect(form.locator("form")).not.toHaveAttribute("aria-busy")
      await expect(form.getByRole("status")).not.toBeEmpty()
      await expect(name).toHaveValue(saved)
      // The press springs back within a moment; once it has, the message beside
      // Save has moved nothing.
      await page.mouse.move(0, 0)
      await expect.poll(place).toEqual(before)
      await expect(page.locator("#account-chip")).toContainText(saved)

      await openAccount(page)
      await expect(page.locator("#account-public-name").getByRole("textbox", {name: "Public Display Name"})).toHaveValue(saved)
      await expect(page.locator("#account-chip")).toContainText(saved)
    })
  })
}
