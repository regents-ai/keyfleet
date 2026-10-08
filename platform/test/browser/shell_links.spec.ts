import {expect, test, type Locator, type Page} from "@playwright/test"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {furnishFleet, prepareFleet} from "./support/fleet_chain"

// Every in-app page is one live view, so a link from one of its pages to
// another patches the page already open: the frame, the live connection and
// the window all stay. A deployed fleet with a room message, a workspace goal
// and a proposal shows every such link, and each is clicked here, signed in
// as the owner of its Key, as only a Key holder reads the workspace.
const fleet = "fibonacci_syndicate"
const me = "0x1111111111111111111111111111111111111111"
const fleetPath = `/app/fleets/${fleet}`
const planPath = new RegExp(`${escape(fleetPath)}/workspace/goal%23\\d+$`)

// The fleet is furnished once, so the specs run in order and stop at the first failure.
test.describe.configure({mode: "serial"})

let key: number

test.beforeAll(() => {
  prepareFleet(fleet)
  key = furnishFleet(fleet, me)
})

function escape(text: string) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

type Frame = {instance: string | null; root: string | null; marker: string | undefined}
type Watched = Window & {shellWalkMarker?: string; shellWalkLoads?: string[]}
type Stop = {path: string | RegExp; shows: string}

// The page as it stands: the shell's instance, the live view's root, and the
// marker left on the window when the walk entered the shell.
const frame = (page: Page): Promise<Frame> =>
  page.evaluate(() => ({
    instance: document.querySelector("#app-shell")?.getAttribute("data-shell-instance") ?? null,
    root: document.querySelector("[data-phx-main]")?.id ?? null,
    marker: (window as Watched).shellWalkMarker,
  }))

// A walk through the shell from the page it entered on. Each link clicked
// must start exactly one page load, a patch; LiveView starts none for Back
// and Forward, whose patches show only in the frame staying the same. The
// page must raise no error on the way.
async function enterShell(page: Page) {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("#app-shell")).toHaveAttribute("data-behavior-ready", "true")
  await page.evaluate(() => {
    const watched = window as Watched
    watched.shellWalkMarker = `walk-${Math.random()}`
    watched.shellWalkLoads = []
    window.addEventListener("phx:page-loading-start", event =>
      watched.shellWalkLoads!.push((event as CustomEvent<{kind: string}>).detail.kind),
    )
  })
  const entered = await frame(page)
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  let clicks = 0

  const arrive = async ({path, shows}: Stop) => {
    await expect(page).toHaveURL(typeof path === "string" ? new RegExp(`${escape(path)}$`) : path)
    await expect(page.locator(shows)).toBeVisible()
    expect(await frame(page), `the frame at ${page.url()}`).toEqual(entered)
  }

  return {
    arrive,
    follow: async (link: Locator, stop: Stop) => {
      await link.click()
      clicks += 1
      await arrive(stop)
    },
    settled: async () => {
      const kinds = await page.evaluate(() => (window as Watched).shellWalkLoads ?? [])
      expect(kinds).toEqual(Array(clicks).fill("patch"))
      expect(errors).toEqual([])
    },
  }
}

const fleetPage: Stop = {path: fleetPath, shows: "#fleet-view"}
const general: Stop = {path: `${fleetPath}/rooms/general`, shows: "#rooms-page"}
const board: Stop = {path: `${fleetPath}/workspace`, shows: "#workspace-page"}
const plan: Stop = {path: planPath, shows: "#workspace-item-page"}
const proposals: Stop = {path: `${fleetPath}/proposals`, shows: "#proposals-page"}
const proposal: Stop = {path: `${fleetPath}/proposals/1`, shows: "#proposal-page"}
const account: Stop = {path: "/account", shows: "#account-page"}

test("the walk from home through every page, back, forward and the sidebar keeps one shell", async ({page}) => {
  const sidebar = page.locator("#shell-sidebar")
  const keyProfile: Stop = {path: `${fleetPath}?key=${key}`, shows: "dialog#key-profile"}

  // Home is its own page; its fleet card is the one full load into the shell.
  // Home's reads land first: leaving mid-read stops the read, which ends the
  // server's one held transaction and every spec after this one.
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto("/")
  await expect(page.locator("#home-tally-agents")).toBeVisible()
  await page.locator(`#home-fleet-${fleet} a.rl-fleet-card__link`).click()
  const walk = await enterShell(page)
  await walk.arrive(fleetPage)

  const stops: [Locator, Stop][] = [
    [page.locator("#fleet-proposals-link"), proposals],
    [page.locator('#proposals-list [data-proposal="1"] h3 a'), proposal],
    [page.locator("#proposal-page .proposals-kicker a"), proposals],
    [page.locator("#proposals-page .proposals-kicker a"), fleetPage],
    [page.locator("#fleet-workspace-link"), board],
    [page.locator("#workspace-page h3 a", {hasText: "Research plan"}), plan],
    [page.locator("#workspace-discussion a"), general],
    [page.locator("#rooms-page .rooms-author a").first(), keyProfile],
    [page.locator("#key-profile-recent a").first(), general],
    [sidebar.getByRole("link", {name: "Account"}), account],
  ]
  for (const [link, stop] of stops) await walk.follow(link, stop)

  // Back six stops, to the fleet page, then forward six, to the Account page.
  const visited = [fleetPage, ...stops.map(([, stop]) => stop)]
  for (let back = 1; back <= 6; back++) {
    await page.goBack()
    await walk.arrive(visited[visited.length - 1 - back])
  }
  for (let back = 5; back >= 0; back--) {
    await page.goForward()
    await walk.arrive(visited[visited.length - 1 - back])
  }

  // The sidebar's links: this fleet, another fleet, and the Account page.
  await walk.follow(sidebar.getByRole("link", {name: "Keyfleet Syndicate"}), fleetPage)
  await walk.follow(sidebar.getByRole("link", {name: "Keyfleet Classic"}), {
    path: "/app/fleets/fleet_tech_classic",
    shows: "#fleet-view",
  })
  await walk.follow(sidebar.getByRole("link", {name: "Account"}), account)

  await walk.settled()
})

test("the links between a fleet's pages each patch the open page", async ({page}) => {
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  await page.goto(fleetPath)
  const walk = await enterShell(page)
  const toFleet = () => walk.follow(page.locator("#shell-sidebar").getByRole("link", {name: "Keyfleet Syndicate"}), fleetPage)

  // The fleet's rooms, workspace and proposals.
  await page.locator("#fleet-rooms-toggle").click()
  await walk.follow(page.locator("#fleet-rooms").getByRole("link", {name: "General"}), general)
  await toFleet()
  await walk.follow(page.locator("#fleet-workspace-link"), board)

  // The workspace's heading leads back to the fleet, and a card's key to the key's page.
  await walk.follow(page.locator("#workspace-page .workspace-kicker a"), fleetPage)
  await walk.follow(page.locator("#fleet-workspace-link"), board)
  await walk.follow(page.locator(`#workspace-page a[href="/app/keys/${fleet}/${key}"]`).first(), {
    path: `/app/keys/${fleet}/${key}`,
    shows: "#key-page",
  })
  await toFleet()

  // A goal on the workspace opens on its own page. A proposal's heading leads
  // to every proposal, and that page's heading back to the fleet.
  await walk.follow(page.locator("#fleet-workspace-link"), board)
  await walk.follow(page.locator("#workspace-page h3 a", {hasText: "Research plan"}), plan)
  await toFleet()
  await walk.follow(page.locator("#fleet-proposals-link"), proposals)
  await walk.follow(page.locator('#proposals-list [data-proposal="1"] h3 a'), proposal)
  await walk.follow(page.locator("#proposal-page .proposals-kicker a"), proposals)
  await walk.follow(page.locator("#proposals-page .proposals-kicker a"), fleetPage)
  await walk.follow(page.locator("#fleet-proposals-link"), proposals)

  await walk.settled()
})
