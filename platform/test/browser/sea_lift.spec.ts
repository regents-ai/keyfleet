import {expect, test} from "@playwright/test"

// The button at the header's far right lifts the page away to show the sea
// behind it, and brings it back. It is drawn as an island over the waves, with
// no box round it and a hairline between it and the control before it.
test("the sea button stands unboxed after a hairline and lifts the page and back", async ({page}) => {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto("/classic/1")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const lift = page.locator("#sea-lift")
  await expect(lift).toHaveAccessibleName("Show the sea")

  const look = await lift.evaluate(button => {
    const style = getComputedStyle(button)
    const rule = getComputedStyle(button, "::before")
    const header = document.querySelector("#shell-header")!
    const controls = [...header.querySelectorAll("button, a")].filter(
      el => el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().right <= button.getBoundingClientRect().left,
    )
    const left = Math.max(...controls.map(el => el.getBoundingClientRect().right))
    const ruleAt = button.getBoundingClientRect().left + parseFloat(rule.left)
    return {
      border: style.borderTopWidth,
      rule: [rule.content, rule.width],
      between: left < ruleAt && ruleAt < button.getBoundingClientRect().left,
    }
  })
  expect(look.border).toBe("0px")
  expect(look.rule).toEqual(['""', "1px"])
  expect(look.between).toBe(true)

  await lift.click()
  await expect(page.locator("body")).toHaveClass(/\bsea-lifted\b/)
  await expect(lift).toHaveAttribute("aria-pressed", "true")
  await expect(lift).toHaveAccessibleName("Bring the page back")
  await expect(page.locator("#app-shell")).toBeHidden()

  await lift.click()
  await expect(page.locator("body")).not.toHaveClass(/\bsea-lifted\b/)
  await expect(lift).toHaveAttribute("aria-pressed", "false")
  await expect(page.locator("#app-shell")).toBeVisible()
  expect(errors).toEqual([])
})
