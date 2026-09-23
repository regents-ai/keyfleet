import {test, expect, devices, type Browser, type BrowserContextOptions} from "@playwright/test"
import {openMap, settle} from "./support/key_map"

// The trace recorder copies the page on every action, which stalls the page for
// 50 ms or so at the start of a drag; the measured runs go without it.
test.use({trace: "off"})

// Performance, measured in Chromium through the DevTools protocol.
type Profile = {
  name: string
  fleet: "Fibonacci" | "Accelerant"
  context: BrowserContextOptions
  throttle: number
  p95: number
  slowFrame: number
  slowShare: number
  scripting: number
  build: number
  tiles: number
}

const laptop = {
  context: {...devices["Desktop Chrome"], viewport: {width: 1440, height: 900}, deviceScaleFactor: 2},
  throttle: 1,
  p95: 17.5,
  slowFrame: 25,
  slowShare: 0.02,
  scripting: 3,
  build: 15,
  tiles: 400,
}

const profiles: Profile[] = [
  {
    name: "laptop",
    fleet: "Fibonacci",
    ...laptop,
  },
  {
    name: "laptop Accelerant",
    fleet: "Accelerant",
    ...laptop,
  },
  {
    name: "phone",
    fleet: "Fibonacci",
    context: {...devices["Pixel 7"]},
    throttle: 4,
    p95: 20,
    slowFrame: 33,
    slowShare: 0.05,
    scripting: 6,
    build: 60,
    tiles: 160,
  },
]

async function measure(browser: Browser, profile: Profile, baseURL: string) {
  const context = await browser.newContext({...profile.context, baseURL})
  const page = await context.newPage()
  await page.addInitScript(() => {
    const longTasks: {start: number; duration: number}[] = []
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) longTasks.push({start: entry.startTime, duration: entry.duration})
    }).observe({type: "longtask", buffered: true})
    // The map's build time, taken from outside it: from the moment the fleet's
    // keys arrive over the socket to the moment the map marks itself ready.
    // Parsing the message is counted too, so this errs on the slow side.
    const builds: {arrived: number; ready?: number}[] = []
    const NativeSocket = window.WebSocket
    window.WebSocket = class extends NativeSocket {
      constructor(...args: ConstructorParameters<typeof WebSocket>) {
        super(...args)
        this.addEventListener("message", event => {
          if (typeof event.data === "string" && event.data.includes('"max_supply"'))
            builds.push({arrived: performance.now()})
        })
      }
    }
    new MutationObserver(records => {
      const ready = records.some(record => (record.target as Element).classList.contains("key-map--ready"))
      const build = builds.at(-1)
      if (ready && build && build.ready === undefined) build.ready = performance.now()
    }).observe(document, {subtree: true, attributes: true, attributeFilter: ["class"]})
    Object.assign(window, {longTasks, builds})
  })
  const cdp = await context.newCDPSession(page)
  await cdp.send("Emulation.setCPUThrottlingRate", {rate: profile.throttle})
  await cdp.send("Performance.enable")

  const {stage} = await openMap(page, profile.fleet)
  const box = (await stage.boundingBox())!
  const start = {x: box.x + box.width * 0.8, y: box.y + box.height * 0.6}
  await settle(page)

  const scriptTime = async () =>
    (await cdp.send("Performance.getMetrics")).metrics.find(metric => metric.name === "ScriptDuration")!.value
  // Frame times, and how many frames drew the map somewhere new.
  await page.evaluate(() => {
    const layer = document.querySelector<HTMLElement>(".km-layer")!
    const frames: number[] = []
    const sampled = {frames, moving: 0, began: performance.now()}
    let last = layer.style.transform
    const sample = (now: number) => {
      frames.push(now)
      if (layer.style.transform !== last) sampled.moving++
      last = layer.style.transform
      if (frames.length < 2_000) requestAnimationFrame(sample)
    }
    requestAnimationFrame(sample)
    Object.assign(window, {sampled})
  })
  const scriptBefore = await scriptTime()

  // Three seconds of dragging in a slow loop around the stage, then a throw
  // and two seconds of coasting.
  await page.mouse.move(start.x, start.y)
  await page.mouse.down()
  const began = Date.now()
  let step = 0
  while (Date.now() - began < 3_000) {
    step++
    const angle = step / 12
    await page.mouse.move(start.x - box.width * 0.3 * (1 - Math.cos(angle)), start.y - box.height * 0.25 * Math.sin(angle))
  }
  const last = {x: start.x - box.width * 0.3, y: start.y}
  await page.mouse.move(last.x, last.y, {steps: 4})
  await page.mouse.move(last.x - 120, last.y - 60, {steps: 4})
  await page.mouse.up()
  await page.waitForTimeout(2_000)

  const scriptAfter = await scriptTime()
  const result = await page.evaluate(() => {
    const {sampled, longTasks, builds} = window as unknown as {
      sampled: {frames: number[]; moving: number; began: number}
      builds: {arrived: number; ready?: number}[]
      longTasks: {start: number; duration: number}[]
    }
    const {frames, moving, began} = sampled
    const intervals = frames.slice(1).map((time, index) => time - frames[index])
    return {
      intervals,
      moving,
      // Only tasks while the map was being moved; loading is held to the build budget.
      longTasks: longTasks.filter(task => task.start + task.duration > began && task.duration > 50),
      build: builds.at(-1)?.ready === undefined ? undefined : builds.at(-1)!.ready! - builds.at(-1)!.arrived,
      tiles: document.querySelector(".km-layer")!.childElementCount,
    }
  })
  await context.close()

  const sorted = [...result.intervals].sort((a, b) => a - b)
  return {
    frames: sorted.length,
    moving: result.moving,
    p95: sorted[Math.floor(sorted.length * 0.95)],
    slowShare: sorted.filter(interval => interval > profile.slowFrame).length / sorted.length,
    scripting: ((scriptAfter - scriptBefore) * 1_000) / sorted.length,
    longTasks: result.longTasks,
    build: result.build,
    tiles: result.tiles,
  }
}

test.describe("key map performance", () => {
  test.skip(({browserName}) => browserName !== "chromium", "measured through the Chromium DevTools protocol")
  test.describe.configure({timeout: 60_000})

  for (const profile of profiles) {
    test(`${profile.name} profile stays within its frame budget`, async ({browser, baseURL}, testInfo) => {
      const result = await measure(browser, profile, baseURL!)
      await testInfo.attach(`${profile.name}-performance`, {
        body: JSON.stringify(result, null, 2),
        contentType: "application/json",
      })
      console.log(`key map ${profile.name}: ${JSON.stringify(result)}`)
      expect(result.frames).toBeGreaterThan(200)
      // The map was really moving for most of the measured time.
      expect(result.moving).toBeGreaterThan(result.frames * 0.6)
      expect(result.p95).toBeLessThanOrEqual(profile.p95)
      expect(result.slowShare).toBeLessThanOrEqual(profile.slowShare)
      expect(result.scripting).toBeLessThanOrEqual(profile.scripting)
      expect(result.longTasks).toEqual([])
      expect(result.build).toBeGreaterThan(0)
      expect(result.build).toBeLessThanOrEqual(profile.build)
      expect(result.tiles).toBeLessThanOrEqual(profile.tiles)
    })
  }
})
