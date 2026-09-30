import {test, expect, type CDPSession, type Page} from "@playwright/test"
import {openMap, settle} from "./support/key_map"

type Point = {x: number; y: number}

const selected = (page: Page) => page.locator("#key-map-selected")

const nextFrame = (page: Page) =>
  page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))))

type Mark = Point & {key: string}

// Where the map sits: the key drawn nearest the middle and its place on screen.
// The map quietly swaps to another copy of itself as it travels, so a key on
// screen is the steady measure, not the layer's own offset.
async function mapAt(page: Page): Promise<Mark> {
  await nextFrame(page)
  return page.evaluate(() => {
    const stage = document.querySelector(".key-map")!.getBoundingClientRect()
    const middle = {x: stage.left + stage.width / 2, y: stage.top + stage.height / 2}
    let nearest = {key: "", x: 0, y: 0, distance: Infinity}
    for (const tile of document.querySelectorAll<HTMLElement>(".km-tile:not([hidden])")) {
      const rect = tile.getBoundingClientRect()
      const [x, y] = [rect.left + rect.width / 2, rect.top + rect.height / 2]
      const distance = Math.hypot(x - middle.x, y - middle.y)
      if (distance < nearest.distance) nearest = {key: tile.dataset.key!, x, y, distance}
    }
    return {key: nearest.key, x: nearest.x, y: nearest.y}
  })
}

// How far the map has moved since `mark`, in whole pixels.
async function movedSince(page: Page, mark: Mark): Promise<Point> {
  await nextFrame(page)
  return page.evaluate(mark => {
    let moved = {x: 0, y: 0, distance: Infinity}
    for (const tile of document.querySelectorAll<HTMLElement>(`.km-tile[data-key="${mark.key}"]:not([hidden])`)) {
      const rect = tile.getBoundingClientRect()
      const [x, y] = [rect.left + rect.width / 2 - mark.x, rect.top + rect.height / 2 - mark.y]
      if (Math.hypot(x, y) < moved.distance) moved = {x, y, distance: Math.hypot(x, y)}
    }
    return {x: Math.round(moved.x), y: Math.round(moved.y)}
  }, mark)
}

const stageCentre = (page: Page) =>
  page.locator(".key-map").evaluate(stage => {
    const rect = stage.getBoundingClientRect()
    return {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2}
  })

// Every copy of a key drawn well inside the stage, nearest the middle first.
const copiesOf = (page: Page, key: number) =>
  page.evaluate(key => {
    const stage = document.querySelector(".key-map")!.getBoundingClientRect()
    const middle = {x: stage.left + stage.width / 2, y: stage.top + stage.height / 2}
    return [...document.querySelectorAll<HTMLElement>(`.km-tile[data-key="${key}"]:not([hidden])`)]
      .map(tile => {
        const rect = tile.getBoundingClientRect()
        return {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, state: tile.dataset.state ?? ""}
      })
      .filter(({x, y}) => x > stage.left + 50 && x < stage.right - 50 && y > stage.top + 50 && y < stage.bottom - 50)
      .sort((a, b) => Math.hypot(a.x - middle.x, a.y - middle.y) - Math.hypot(b.x - middle.x, b.y - middle.y))
  }, key)

// Every key drawn with its centre inside the stage: its number, marks and place.
const onScreen = (page: Page) =>
  page.evaluate(() => {
    const stage = document.querySelector(".key-map")!.getBoundingClientRect()
    return [...document.querySelectorAll<HTMLElement>(".km-tile:not([hidden])")]
      .map(tile => {
        const rect = tile.getBoundingClientRect()
        return {key: Number(tile.dataset.key), state: tile.dataset.state ?? "", x: rect.left + rect.width / 2, y: rect.top + rect.height / 2}
      })
      .filter(({x, y}) => x > stage.left && x < stage.right && y > stage.top && y < stage.bottom)
      .sort((a, b) => a.key - b.key || a.y - b.y || a.x - b.x)
  })

async function tile(page: Page, key: number): Promise<Point> {
  const [copy] = await copiesOf(page, key)
  expect(copy, `key ${key} is on screen`).toBeDefined()
  return copy
}

// A throw at about a hand's speed: six moves a frame apart and a release with no rest.
async function fling(page: Page, from: Point, dx: number) {
  await page.mouse.move(from.x, from.y)
  await page.mouse.down()
  for (let step = 1; step <= 6; step++) {
    await page.waitForTimeout(16)
    await page.mouse.move(from.x + (dx * step) / 6, from.y)
  }
  await page.mouse.up()
}

// How large the map is drawn: 1, but during Classic's opening zoom.
const zoomOf = (page: Page) =>
  page.locator(".km-layer").evaluate(layer => Number(/scale\(([^)]+)\)/.exec((layer as HTMLElement).style.transform)![1]))

// Opens Classic and, on its first frame, reads how large it is drawn and
// which keys have their middles inside the stage.
async function openClassic(page: Page) {
  await page.goto("/showcase/key-map")
  await expect(page.locator(".key-map.key-map--ready")).toBeVisible()
  // Classic's stage takes the place of the first, with its middle on screen.
  await page.locator(".key-map").evaluate(stage => stage.scrollIntoView({block: "center"}))
  await page.getByRole("button", {name: /^Classic/}).click()
  return page.evaluate(
    () =>
      new Promise<{zoom: number; keys: number}>(done => {
        const look = () => {
          const stage = document.querySelector<HTMLElement>("#key-map-classic.key-map--ready")
          const layer = stage?.querySelector<HTMLElement>(".km-layer")
          if (!stage || !layer?.style.transform) return requestAnimationFrame(look)
          const box = stage.getBoundingClientRect()
          const keys = new Set(
            [...stage.querySelectorAll<HTMLElement>(".km-tile:not([hidden])")]
              .filter(tile => {
                const rect = tile.getBoundingClientRect()
                const [x, y] = [rect.left + rect.width / 2, rect.top + rect.height / 2]
                return x > box.left && x < box.right && y > box.top && y < box.bottom
              })
              .map(tile => tile.dataset.key),
          )
          done({zoom: Number(/scale\(([^)]+)\)/.exec(layer.style.transform)![1]), keys: keys.size})
        }
        look()
      }),
  )
}


test.describe("key map", () => {
  test("a click chooses the key under it", async ({page}) => {
    const {errors} = await openMap(page, "Accelerant")
    await expect(selected(page)).toHaveText("No key chosen yet.")
    const target = await tile(page, 1_999)
    await page.mouse.click(target.x, target.y)
    await expect(selected(page)).toHaveText("Key 1,999 chosen.")
    expect(errors).toEqual([])
  })

  test("a 200 px drag that starts on a key moves the map and chooses nothing", async ({page}) => {
    await openMap(page, "Accelerant")
    const start = await tile(page, 1_999)
    const before = await mapAt(page)
    await page.mouse.move(start.x, start.y)
    await page.mouse.down()
    await page.mouse.move(start.x - 200, start.y, {steps: 20})
    // A rest before letting go, so the map stays where the drag left it.
    await page.waitForTimeout(150)
    await page.mouse.up()
    expect(await movedSince(page, before)).toEqual({x: -200, y: 0})
    await settle(page)
    await expect(selected(page)).toHaveText("No key chosen yet.")
  })

  test("a press while the map coasts stops it and chooses nothing", async ({page}) => {
    await openMap(page, "Accelerant")
    const centre = await stageCentre(page)
    await fling(page, centre, -120)
    const released = await mapAt(page)
    await page.waitForTimeout(60)
    expect((await movedSince(page, released)).x, "the map coasts after a throw").toBeLessThan(0)

    await page.mouse.click(centre.x, centre.y)
    const stopped = await mapAt(page)
    await page.waitForTimeout(250)
    expect(await movedSince(page, stopped)).toEqual({x: 0, y: 0})
    await expect(selected(page)).toHaveText("No key chosen yet.")
  })

  test("the wheel pans the map and leaves the page where it is", async ({page}) => {
    await openMap(page, "Fibonacci")
    const centre = await stageCentre(page)
    const scrolled = await page.evaluate(() => scrollY)
    const before = await mapAt(page)
    await page.mouse.move(centre.x, centre.y)
    await page.mouse.wheel(120, 300)
    await expect.poll(() => movedSince(page, before)).toEqual({x: -120, y: -300})
    expect(await page.evaluate(() => scrollY)).toBe(scrolled)
  })

  test("keys fill the stage to its edges wherever the map is moved", async ({page}) => {
    const {stage} = await openMap(page, "Fibonacci")
    const centre = await stageCentre(page)
    await page.mouse.move(centre.x, centre.y)
    // The map opens on the available key, the sixth in a 28-key row of level 19.
    // Eight 96 px cells across and 36 rows down is the middle of that level,
    // where every cell holds a key.
    await page.mouse.wheel(768, 3_000)
    for (let step = 0; step < 16; step++) {
      await page.mouse.wheel(37, 23)
      await nextFrame(page)
      const uncovered = await stage.evaluate(stage => {
        const box = stage.getBoundingClientRect()
        const tiles = [...stage.querySelectorAll<HTMLElement>(".km-tile:not([hidden])")].map(tile =>
          tile.getBoundingClientRect(),
        )
        // Tiles sit 6 px apart, so a point within 4 px of a tile's box is covered.
        const covered = (x: number, y: number) =>
          tiles.some(rect => x >= rect.left - 4 && x <= rect.right + 4 && y >= rect.top - 4 && y <= rect.bottom + 4)
        const points: [number, number][] = []
        for (let x = box.left + 2; x < box.right; x += 20) points.push([x, box.top + 2], [x, box.bottom - 2])
        for (let y = box.top + 2; y < box.bottom; y += 20) points.push([box.left + 2, y], [box.right - 2, y])
        return points.filter(([x, y]) => !covered(x, y))
      })
      expect(uncovered, `step ${step}`).toEqual([])
    }
  })

  test("every copy of a key carries the same marks, a whole copy apart", async ({page}) => {
    const {stage} = await openMap(page, "Accelerant")
    const target = await tile(page, 1_999)
    await page.mouse.click(target.x, target.y)
    await expect(selected(page)).toHaveText("Key 1,999 chosen.")
    // Accelerant's map is five keys wide with 22 empty cells beside it, so it
    // repeats every 27 cells across.
    const period = 27 * (await stage.evaluate(stage => parseFloat(getComputedStyle(stage).getPropertyValue("--km-cell"))))
    const centre = await stageCentre(page)
    await page.mouse.move(centre.x, centre.y)

    const marks = new Set<string>()
    const check = async () => {
      const here = await onScreen(page)
      expect(here.length).toBeGreaterThan(10)
      // Every key matches the page's made-up owners and agents.
      for (const {key, state} of here) {
        const expected = [key === 2_000 && "available", key % 97 === 13 && "mine", key % 7 === 3 && "agent", key === 1_999 && "selected"]
        expect(state, `key ${key}`).toBe(expected.filter(Boolean).join(" "))
        state.split(" ").forEach(mark => marks.add(mark))
      }
      // A whole copy across, the same keys sit in the same places with the same marks.
      await page.mouse.wheel(period, 0)
      await nextFrame(page)
      const there = await onScreen(page)
      expect(there.map(({key, state}) => `${key} ${state}`)).toEqual(here.map(({key, state}) => `${key} ${state}`))
      there.forEach((copy, index) => expect(Math.hypot(copy.x - here[index].x, copy.y - here[index].y)).toBeLessThan(1))
    }
    await check()
    // Nine rows up sits 1,953, one of the keys marked as yours.
    await page.mouse.wheel(0, -700)
    await nextFrame(page)
    await check()
    expect([...marks]).toEqual(expect.arrayContaining(["mine", "agent", "selected"]))
  })

  // The pyramid is 45 rows, far taller than the stage at normal size.
  test("Classic opens on its whole pyramid, then zooms in to the available key", async ({page}) => {
    const first = await openClassic(page)
    expect(first.zoom).toBeLessThan(1)
    expect(first.keys).toBe(1_024)

    const centre = await stageCentre(page)
    await expect.poll(() => zoomOf(page)).toBe(1)
    const available = await tile(page, 1_024)
    expect(Math.hypot(available.x - centre.x, available.y - centre.y)).toBeLessThanOrEqual(1)
  })

  test("a press during Classic's opening zoom stops it at once, at normal size, and chooses nothing", async ({page}) => {
    expect((await openClassic(page)).zoom).toBeLessThan(1)
    const centre = await stageCentre(page)
    await page.mouse.click(centre.x, centre.y)
    await nextFrame(page)
    expect(await zoomOf(page)).toBe(1)
    const stopped = await mapAt(page)
    await page.waitForTimeout(300)
    expect(await movedSince(page, stopped)).toEqual({x: 0, y: 0})
    await expect(selected(page)).toHaveText("No key chosen yet.")
  })

  // Accelerant's keys run in rows of five, snaking; with 1,990 sold, keys
  // 1,991 to 1,995 make one row from left to right.
  test("a key that can't be bought yet says so, by mouse or arrow key, and never blocks a drag", async ({page}) => {
    const {stage} = await openMap(page, "Accelerant")
    await page.getByLabel("Keys sold").fill("1990")
    await expect(stage.locator('.km-tile[data-key="1991"]:not([hidden])').first()).toHaveAttribute("data-state", /available/)
    const note = stage.locator(".km-note")

    const later = await tile(page, 1_993)
    await page.mouse.move(later.x, later.y)
    await expect(note).toBeVisible()
    await expect(note).toHaveText("The preceding key must be sold.")
    const box = (await note.boundingBox())!
    expect(Math.abs(box.x + box.width / 2 - later.x)).toBeLessThanOrEqual(1)
    expect(box.y + box.height).toBeLessThan(later.y)

    // The available key and sold keys have no note.
    for (const key of [1_991, 1_987]) {
      const at = await tile(page, key)
      await page.mouse.move(at.x, at.y)
      await page.waitForTimeout(500)
      await expect(note).toBeHidden()
    }

    // A drag that starts on the note moves the map.
    await page.mouse.move(later.x, later.y)
    await expect(note).toBeVisible()
    const noteAt = {x: box.x + box.width / 2, y: box.y + box.height / 2}
    const before = await mapAt(page)
    await page.mouse.move(noteAt.x, noteAt.y)
    await page.mouse.down()
    await page.mouse.move(noteAt.x - 150, noteAt.y, {steps: 15})
    await page.waitForTimeout(150)
    await page.mouse.up()
    expect(await movedSince(page, before)).toEqual({x: -150, y: 0})
    await expect(selected(page)).toHaveText("No key chosen yet.")

    await stage.focus()
    await page.keyboard.press("Home")
    await expect(note).toBeHidden()
    await page.keyboard.press("ArrowRight")
    await expect(stage.locator("[aria-live=polite]")).toHaveText("Key 1,992, not sold yet.")
    await expect(note).toBeVisible()
    await page.keyboard.press("ArrowLeft")
    await expect(note).toBeHidden()
  })

  test.describe("on a tall screen", () => {
    // The stage is 820 px tall, so six rows around the available key all fit.
    test.use({viewport: {width: 1280, height: 1200}})

    test("Classic draws its pyramid to three rows below the row on sale", async ({page}) => {
      const {stage, errors} = await openMap(page, "Classic")
      const status = stage.locator("[aria-live=polite]")
      const drawn = async () => [...new Set((await onScreen(page)).map(({key}) => key))].sort((a, b) => a - b)
      const upTo = (last: number) => Array.from({length: last}, (_, index) => index + 1)
      const available = (key: number) =>
        expect(stage.locator(`.km-tile[data-key="${key}"]:not([hidden])`).first()).toHaveAttribute("data-state", /available/)

      // Nothing sold: key 1 is on sale and rows 1 to 4 are drawn.
      await page.getByLabel("Keys sold").fill("0")
      await available(1)
      await expect.poll(drawn).toEqual(upTo(10))
      // Key 5, in row 3, is on sale: rows 1 to 6 are drawn.
      await page.getByLabel("Keys sold").fill("4")
      await available(5)
      await stage.focus()
      await page.keyboard.press("Home")
      await expect(status).toHaveText("Available key, 5.")
      await expect.poll(drawn).toEqual(upTo(21))
      // Row 3 is 4 5 6.
      await page.keyboard.press("ArrowRight")
      await expect(status).toHaveText("Key 6, not sold yet.")
      await page.keyboard.press("ArrowLeft")
      await page.keyboard.press("ArrowLeft")
      await expect(status).toHaveText("Key 4.")
      await page.keyboard.press("Enter")
      await expect(selected(page)).toHaveText("Key 4 chosen.")
      expect(errors).toEqual([])
    })
  })

  test("arrow keys, Enter and Home move and choose", async ({page}) => {
    const {stage} = await openMap(page, "Accelerant")
    const status = stage.locator("[aria-live=polite]")
    await stage.focus()
    await page.keyboard.press("Home")
    await expect(status).toHaveText("Available key, 2,000.")
    await page.keyboard.press("ArrowRight")
    await expect(status).toHaveText("Key 1,999.")
    await page.keyboard.press("ArrowUp")
    await expect(status).toHaveText("Key 1,992.")
    const cursorCopies = await copiesOf(page, 1_992)
    expect(cursorCopies.length).toBeGreaterThan(0)
    for (const copy of cursorCopies) expect(copy.state.split(" ")).toContain("cursor")
    // Shortcuts with a modifier are left to the browser.
    await page.keyboard.press("Control+ArrowRight")
    await expect(status).toHaveText("Key 1,992.")
    await page.keyboard.press("Enter")
    await expect(selected(page)).toHaveText("Key 1,992 chosen.")
    await page.keyboard.press("ArrowRight")
    await page.keyboard.press(" ")
    await expect(selected(page)).toHaveText("Key 1,993 chosen.")

    // Without a cursor, Space neither chooses a key nor scrolls the page.
    await page.keyboard.press("Escape")
    const scrolled = await page.evaluate(() => scrollY)
    await page.keyboard.press(" ")
    await nextFrame(page)
    expect(await page.evaluate(() => scrollY)).toBe(scrolled)
    await expect(selected(page)).toHaveText("Key 1,993 chosen.")

    // Home brings the available key back to the middle from anywhere.
    const centre = await stageCentre(page)
    await page.mouse.move(centre.x, centre.y)
    await page.mouse.wheel(900, 0)
    await page.keyboard.press("Home")
    await expect.poll(async () => {
      const [available] = await copiesOf(page, 2_000)
      return available ? Math.round(Math.hypot(available.x - centre.x, available.y - centre.y)) : Infinity
    }).toBeLessThanOrEqual(1)
  })

  test("the page scrolls normally outside the map", async ({page}) => {
    await openMap(page, "Fibonacci")
    await page.evaluate(() => scrollTo(0, 0))
    const notes = page.locator(".key-map-reference__notes")
    const header = page.locator(".sc-header")
    const box = (await header.boundingBox())!
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
    await page.mouse.wheel(0, 400)
    await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(0)
    await expect(notes).toBeInViewport()
  })

  test.describe("with reduced motion", () => {
    test.use({contextOptions: {reducedMotion: "reduce"}})

    test("a throw stops on release and Home jumps straight to the available key", async ({page}) => {
      const {stage} = await openMap(page, "Accelerant")
      expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true)
      const centre = await stageCentre(page)
      await fling(page, centre, -120)
      const released = await mapAt(page)
      await page.waitForTimeout(200)
      expect(await movedSince(page, released)).toEqual({x: 0, y: 0})

      await stage.focus()
      await page.keyboard.press("Home")
      // One frame later the available key is already in the middle, and stays there.
      await page.evaluate(() => new Promise(requestAnimationFrame))
      const available = await tile(page, 2_000)
      expect(Math.hypot(available.x - centre.x, available.y - centre.y)).toBeLessThanOrEqual(1)
      const landed = await mapAt(page)
      await page.waitForTimeout(200)
      expect(await movedSince(page, landed)).toEqual({x: 0, y: 0})
    })

    test("Classic lands straight on the available key", async ({page}) => {
      expect((await openClassic(page)).zoom).toBe(1)
      const centre = await stageCentre(page)
      const available = await tile(page, 1_024)
      expect(Math.hypot(available.x - centre.x, available.y - centre.y)).toBeLessThanOrEqual(1)
    })
  })
})

// Touch, sent through the Chromium DevTools protocol as real touch input.
test.describe("key map by touch", () => {
  test.skip(({browserName}) => browserName !== "chromium", "touch input is sent through the Chromium DevTools protocol")
  test.use({hasTouch: true})

  type Finger = Point & {id: number}
  const touch = (cdp: CDPSession, type: "touchStart" | "touchMove" | "touchEnd", fingers: Finger[]) =>
    cdp.send("Input.dispatchTouchEvent", {type, touchPoints: fingers.map(({x, y, id}) => ({x, y, id}))})

  async function open(page: Page) {
    await openMap(page, "Accelerant")
    return page.context().newCDPSession(page)
  }

  async function tap(cdp: CDPSession, at: Point) {
    await touch(cdp, "touchStart", [{...at, id: 0}])
    await touch(cdp, "touchEnd", [])
  }

  test("a tap chooses a key, even with a 10 px wobble", async ({page}) => {
    const cdp = await open(page)
    const first = await tile(page, 1_999)
    await tap(cdp, first)
    await expect(selected(page)).toHaveText("Key 1,999 chosen.")

    const second = await tile(page, 1_998)
    await touch(cdp, "touchStart", [{...second, id: 0}])
    await touch(cdp, "touchMove", [{x: second.x + 6, y: second.y + 8, id: 0}])
    await touch(cdp, "touchMove", [{...second, id: 0}])
    await touch(cdp, "touchEnd", [])
    await expect(selected(page)).toHaveText("Key 1,998 chosen.")
  })

  test("a drag moves the map and chooses nothing", async ({page}) => {
    const cdp = await open(page)
    const start = await tile(page, 1_999)
    const before = await mapAt(page)
    await touch(cdp, "touchStart", [{...start, id: 0}])
    for (let step = 1; step <= 10; step++) await touch(cdp, "touchMove", [{x: start.x - step * 10, y: start.y, id: 0}])
    await page.waitForTimeout(150)
    await touch(cdp, "touchEnd", [])
    expect(await movedSince(page, before)).toEqual({x: -100, y: 0})
    await settle(page)
    await expect(selected(page)).toHaveText("No key chosen yet.")
  })

  test("a second finger is ignored", async ({page}) => {
    const cdp = await open(page)
    const held = await tile(page, 1_999)
    const other = await tile(page, 1_996)
    const before = await mapAt(page)
    await touch(cdp, "touchStart", [{...held, id: 0}])
    await touch(cdp, "touchStart", [{...held, id: 0}, {...other, id: 1}])
    for (let step = 1; step <= 10; step++)
      await touch(cdp, "touchMove", [{...held, id: 0}, {x: other.x - step * 15, y: other.y, id: 1}])
    await touch(cdp, "touchEnd", [{...held, id: 0}])
    await touch(cdp, "touchEnd", [])
    expect(await movedSince(page, before)).toEqual({x: 0, y: 0})
    await expect(selected(page)).toHaveText("Key 1,999 chosen.")
  })

  test("a tap while the map coasts stops it and chooses nothing", async ({page}) => {
    const cdp = await open(page)
    const centre = await stageCentre(page)
    await touch(cdp, "touchStart", [{...centre, id: 0}])
    for (let step = 1; step <= 6; step++) {
      await page.waitForTimeout(16)
      await touch(cdp, "touchMove", [{x: centre.x - step * 20, y: centre.y, id: 0}])
    }
    await touch(cdp, "touchEnd", [])
    const released = await mapAt(page)
    await page.waitForTimeout(60)
    expect((await movedSince(page, released)).x, "the map coasts after a throw").toBeLessThan(0)

    await tap(cdp, centre)
    const stopped = await mapAt(page)
    await page.waitForTimeout(250)
    expect(await movedSince(page, stopped)).toEqual({x: 0, y: 0})
    await expect(selected(page)).toHaveText("No key chosen yet.")
  })
})
