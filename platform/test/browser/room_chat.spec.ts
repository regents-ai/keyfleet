import {randomBytes} from "node:crypto"
import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey, talk} from "./support/fleet_chain"
import {newAgent, pairAgent} from "./support/agent_tools"

// A room opens at its newest post with the box to write in under it, however
// it is reached, and stays there as posts arrive, unless the reader scrolled
// up to read. Each post's first line offers the Key's profile, a copy of the
// wallet and a mute: with a mouse while the line is pointed at or reached by
// keyboard, on a touch screen always. Every walk writes its own posts as a Key
// of its own, so a retried walk never meets another's, and unmutes what it
// muted.
const fleet = "fleet_tech_accelerant"
const hall = "/accelerant/1"
const people = `${hall}?room=people`

// The walk's person (Keyfleet.TestPrivyVerifier, "valid"), who holds a Key to
// write in the People and agents room.
const me = `0x${"1".repeat(40)}`

const someone = () => `0x${randomBytes(20).toString("hex")}`
const words = () => randomBytes(4).toString("hex")

test.beforeAll(() => {
  prepareFleet(fleet)
  sellKey(fleet, me)
  pairAgent(newAgent(), me)
})

const phone = {viewport: {width: 360, height: 780}, isMobile: true, hasTouch: true}

async function signIn(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  return errors
}

async function open(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

/** A Key sold to a new owner, whose agent says `body 1` up to `body times` in `room`. */
function speaker(room: string, body: string, times: number) {
  const owner = someone()
  const key = sellKey(fleet, owner)
  talk(fleet, owner, room, body, times)
  return {owner, key}
}

const post = (page: Page, text: string) =>
  page.locator("#rooms-thread-list > li", {has: page.locator(".rooms-body").getByText(text, {exact: true})})

// The room at its end: the box to write in on the screen and the newest post
// ending just above it, in view. A wide screen's hall can be too short for
// the whole of both, and then shows the newest post's end.
async function expectNewest(page: Page, newest: string, oldest: string) {
  await expect(page.locator("#rooms-composer")).toBeInViewport({ratio: 1})
  await expect(post(page, newest)).toBeInViewport()
  await expect
    .poll(() =>
      post(page, newest).evaluate(item => {
        const shown = Math.max(item.closest(".rooms-thread")!.getBoundingClientRect().top, 0)
        const {bottom} = item.getBoundingClientRect()
        return bottom > shown && bottom <= innerHeight
      }),
    )
    .toBe(true)
  await expect(post(page, oldest)).not.toBeInViewport()
}

// Where a post stands once the list stops moving: two readings a tenth of a
// second apart agree.
async function settledTop(item: Locator) {
  let last = Number.NaN
  await expect
    .poll(
      async () => {
        const top = (await item.boundingBox())!.y
        const still = Math.abs(top - last) < 0.5
        last = top
        return still
      },
      {intervals: [100]},
    )
    .toBe(true)
  return last
}

for (const [profile, use] of [
  ["desktop", {}],
  ["phone", phone],
] as const) {
  test.describe(profile, () => {
    test.use(use)

    test("a long room opens at its newest post, on first load, from the hall and after going back", async ({page}) => {
      const said = words()
      speaker("people", said, 30)
      const errors = await signIn(page)

      await open(page, people)
      await expectNewest(page, `${said} 30`, `${said} 1`)

      // A connection that comes back draws the room again, at its newest post.
      await post(page, `${said} 1`).scrollIntoViewIfNeeded()
      await page.evaluate(() => {
        const {liveSocket} = window as unknown as {liveSocket: {disconnect(): void; connect(): void}}
        liveSocket.disconnect()
        liveSocket.connect()
      })
      await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
      await expectNewest(page, `${said} 30`, `${said} 1`)

      await open(page, hall)
      await page.locator("#fleet-room-people").click()
      await expect(page).toHaveURL(/room=people/)
      await expectNewest(page, `${said} 30`, `${said} 1`)

      await page.locator("#fleet-room-general").click()
      await expect(page).toHaveURL(/room=general/)
      await page.goBack()
      await expect(page).toHaveURL(/room=people/)
      await expectNewest(page, `${said} 30`, `${said} 1`)

      expect(errors).toEqual([])
    })

    test("a short room shows its few posts just above the box to write in", async ({page}) => {
      const said = words()
      speaker("coding", said, 2)
      const errors = await signIn(page)

      await open(page, `${hall}?room=coding`)
      const newest = post(page, `${said} 2`)
      await expect(newest).toBeInViewport({ratio: 1})
      await expect(post(page, `${said} 1`)).toBeInViewport({ratio: 1})
      const foot = page.locator(".rooms-foot")
      await expect(foot).toBeInViewport({ratio: 1})
      const gap = (await foot.boundingBox())!.y - (await newest.boundingBox())!.y - (await newest.boundingBox())!.height
      expect(gap).toBeLessThan(40)

      expect(errors).toEqual([])
    })

    test("a new post keeps a reader at the bottom there, and leaves one who scrolled up where they were", async ({page}) => {
      const said = words()
      const {owner} = speaker("people", said, 30)
      const errors = await signIn(page)
      await open(page, people)
      await expectNewest(page, `${said} 30`, `${said} 1`)

      talk(fleet, owner, "people", `${said} late`, 1)
      await expectNewest(page, `${said} late 1`, `${said} 1`)

      const anchor = post(page, `${said} 10`)
      await anchor.scrollIntoViewIfNeeded()
      const before = await settledTop(anchor)
      talk(fleet, owner, "people", `${said} later`, 1)
      const later = post(page, `${said} later 1`)
      await expect(later).toBeAttached()
      await settledTop(later)
      expect(Math.abs((await settledTop(anchor)) - before)).toBeLessThanOrEqual(1)
      await expect(later).not.toBeInViewport()

      await page.locator("#rooms-composer-body").fill(`${said} mine`)
      await page.locator("#rooms-composer").getByRole("button").click()
      await expectNewest(page, `${said} mine`, `${said} 1`)

      // With motion reduced, a post that arrives still keeps the reader there.
      const probe = () =>
        page.evaluate(() => {
          const r = document.querySelector(".rooms-thread")!
          const s = document.getElementById("app-shell-scroller")!
          const b = r.getBoundingClientRect()
          let far: Element | null = null
          let farBottom = -Infinity
          const styled: string[] = []
          for (const el of r.querySelectorAll("*")) {
            const bottom = el.getBoundingClientRect().bottom
            if (bottom > farBottom) [far, farBottom] = [el, bottom]
            const style = (el as HTMLElement).getAttribute("style")
            if (style) styled.push(`${el.tagName}#${el.id}.${el.className}: ${style}`.slice(0, 160))
          }
          const farthest = far as Element | null
          return JSON.stringify({sh: r.scrollHeight, st: r.scrollTop, ch: r.clientHeight, bottom: b.bottom, ih: innerHeight, sst: s.scrollTop, smax: s.scrollHeight - s.clientHeight, sbottom: s.getBoundingClientRect().bottom, far: farthest && `${farthest.tagName}#${farthest.id}.${farthest.className}`, farBottom, styled: styled.slice(0, 12), nstyled: styled.length})
        })
      console.log("PROBE after mine", await probe())
      await page.evaluate(() => {
        const log: unknown[] = []
        ;(window as unknown as {__log: unknown[]}).__log = log
        const t0 = performance.now()
        document.addEventListener("scroll", e => {
          const t = (e.target instanceof Element ? e.target : document.scrollingElement)!
          log.push(["scroll", Math.round(performance.now() - t0), t.id || t.className, Math.round(t.scrollTop)])
        }, {capture: true, passive: true})
        const room = document.querySelector(".rooms-thread")!
        new ResizeObserver(entries => log.push(["resize", Math.round(performance.now() - t0), entries.map(e => (e.target as Element).id || (e.target as Element).className).join("+"), room.scrollHeight, Math.round(room.scrollTop)])).observe(document.querySelector("#rooms-thread-list")!)
      })
      await page.emulateMedia({reducedMotion: "reduce"})
      console.log("PROBE after media", await probe())
      talk(fleet, owner, "people", `${said} still`, 1)
      await expect(post(page, `${said} still 1`)).toBeAttached()
      await page.waitForTimeout(1500)
      console.log("PROBE after still", await probe())
      console.log("LOG", JSON.stringify(await page.evaluate(() => (window as unknown as {__log: unknown[]}).__log)))
      await expectNewest(page, `${said} still 1`, `${said} 1`)

      expect(errors).toEqual([])
    })

    test("a full room of 200 posts stays at its newest post as more arrive", async ({page}) => {
      test.setTimeout(240_000)
      const said = words()
      const {owner} = speaker("people", said, 100)
      const errors = await signIn(page)
      await open(page, people)
      await expectNewest(page, `${said} 100`, `${said} 1`)

      // A room opens at its newest hundred posts and keeps up to 200. A
      // hundred more come twenty at a time, each post its own change to the
      // page, which lands about two a second here; a hundred at once keep the
      // page busy so long that the room is drawn again from its newest hundred.
      for (const round of [1, 2, 3, 4, 5]) {
        talk(fleet, owner, "people", `${said} more${round}`, 20)
        await expect(post(page, `${said} more${round} 20`)).toBeAttached({timeout: 30_000})
      }
      await expect(page.locator("#rooms-thread-list > li")).toHaveCount(200)
      await expectNewest(page, `${said} more5 20`, `${said} 1`)

      // One more lets the oldest go, and the reader stays at the newest.
      talk(fleet, owner, "people", `${said} last`, 1)
      await expect(post(page, `${said} 1`)).toHaveCount(0)
      await expect(page.locator("#rooms-thread-list > li")).toHaveCount(200)
      await expectNewest(page, `${said} last 1`, `${said} 2`)

      expect(errors).toEqual([])
    })

    test("a post's sender line offers the Key's profile, a copy of the wallet and a mute", async ({page}) => {
      const said = words()
      const {key} = speaker("people", said, 3)
      const errors = await signIn(page)
      await open(page, people)

      const line = post(page, `${said} 3`).locator(".rooms-author")
      const actions = line.locator(".rooms-actions")
      const profileLink = line.getByRole("link", {name: `Key ${key} profile`})
      await line.scrollIntoViewIfNeeded()
      await expect(actions.locator(".rooms-action")).toHaveCount(3)

      if (profile === "desktop") {
        await page.mouse.move(1, 1)
        await expect(actions).toHaveCSS("opacity", "0")
        const height = (await line.boundingBox())!.height

        await line.hover()
        await expect(actions).toHaveCSS("opacity", "1")
        expect((await line.boundingBox())!.height).toBe(height)

        await page.mouse.move(1, 1)
        await expect(actions).toHaveCSS("opacity", "0")
        await line.getByRole("link", {name: `Key ${key}`, exact: true}).focus()
        await page.keyboard.press("Tab")
        await expect(profileLink).toBeFocused()
        await expect(actions).toHaveCSS("opacity", "1")
        expect((await line.boundingBox())!.height).toBe(height)
      } else {
        await expect(actions).toHaveCSS("opacity", "1")
        const tops = await actions.locator(".rooms-action").evaluateAll(buttons =>
          buttons.map(button => Math.round(button.getBoundingClientRect().top)),
        )
        expect(new Set(tops).size).toBe(1)
        const keyBox = (await line.getByRole("link", {name: `Key ${key}`, exact: true}).boundingBox())!
        const actionsBox = (await actions.boundingBox())!
        const lineBox = (await line.boundingBox())!
        expect(actionsBox.y).toBeLessThan(keyBox.y + keyBox.height)
        expect(actionsBox.x + actionsBox.width).toBeLessThanOrEqual(lineBox.x + lineBox.width)
      }

      await profileLink.click()
      await expect(page).toHaveURL(new RegExp(`key=${key}`))
      await expect(page.locator("#key-profile")).toBeVisible()
      await expect(page.locator("#rooms-thread")).toBeAttached()

      expect(errors).toEqual([])
    })

    test("copy puts the wallet on the clipboard, and mute hides the Key until unmuted", async ({page, context}) => {
      await context.grantPermissions(["clipboard-read", "clipboard-write"])
      const said = words()
      const {owner, key} = speaker("people", said, 3)
      const errors = await signIn(page)
      await open(page, people)

      const line = post(page, `${said} 3`).locator(".rooms-author")
      const copy = line.getByRole("button", {name: "Copy wallet"})
      await copy.click()
      await expect(copy).toHaveAttribute("data-copy-state", "copied")
      expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(owner)

      await line.getByRole("button", {name: `Mute Key ${key}`}).click()
      await expect(post(page, `${said} 3`)).toHaveCount(0)
      await expect(post(page, `${said} 1`)).toHaveCount(0)
      await expect(page.locator(`#rooms-muted-${key}`)).toBeVisible()

      await page.locator(`#rooms-unmute-${key}`).click()
      await expect(post(page, `${said} 3`)).toBeVisible()
      await expect(page.locator("#rooms-muted")).toHaveCount(0)

      expect(errors).toEqual([])
    })
  })
}

// On a wide screen the room scrolls in its own column, and is drawn at its
// newest post from the first moment, before the page's scripts start; until
// then, nobody is signed in.
test.describe("before the page's scripts run", () => {
  test.use({javaScriptEnabled: false})

  test("a long room is drawn at its newest post", async ({page}) => {
    const said = words()
    speaker("people", said, 30)

    await page.goto(people)
    await expect(page.locator("#rooms-key-holders")).toBeInViewport({ratio: 1})
    await expect(post(page, `${said} 30`)).toBeInViewport()
    await expect(post(page, `${said} 1`)).not.toBeInViewport()
  })
})
