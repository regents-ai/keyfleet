import {expect, test, type Page} from "@playwright/test"
import {newAgent, pairPerson, useCode} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {prepareFleet, sellKey} from "./support/fleet_chain"

// A person manages their paired agents on the Agents page, as on regents.sh:
// See what it has done opens the agent's window, Done closes it, and Unpair,
// once confirmed in the site's confirm window, takes the agent off the account. Both
// windows are the shared cut-corner dialog, on a wide screen and on a phone.
const person = "did:privy:verified"

async function signIn(page: Page) {
  const errors: string[] = []
  page.on("pageerror", error => errors.push(error.message))
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()
  return errors
}

async function openAgents(page: Page) {
  await page.goto("/account/agents")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
}

for (const viewport of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
  test(`at ${viewport.width} px, an agent's window opens and closes, and Unpair takes the agent off the account`, async ({page}) => {
    await page.setViewportSize(viewport)
    const name = `Astra ${viewport.width}`
    pairPerson(newAgent(), person, name)
    const errors = await signIn(page)
    await openAgents(page)

    const row = page.locator("#account-agents li", {hasText: name})
    const dialog = page.locator("#account-agent-dialog")
    await row.getByRole("button", {name: `See what ${name} has done`}).click()
    await expect(dialog).toBeVisible()
    await expect(dialog.getByRole("heading", {name})).toBeVisible()
    const box = (await dialog.boundingBox())!
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(viewport.width)

    await dialog.getByRole("button", {name: "Done"}).click()
    await expect(dialog).toBeHidden()

    await row.getByRole("button", {name: `See what ${name} has done`}).click()
    await expect(dialog).toBeVisible()
    const confirm = page.locator("#rg-confirm")
    await dialog.getByRole("button", {name: "Unpair"}).click()
    await expect(confirm).toBeVisible()
    await expect(confirm).toHaveAccessibleName(`Unpair ${name}? It will need a new code to pair again.`)
    await expect(confirm.getByRole("button", {name: "Cancel"})).toBeFocused()
    const frame = (await confirm.boundingBox())!
    expect(frame.x).toBeGreaterThanOrEqual(0)
    expect(frame.x + frame.width).toBeLessThanOrEqual(viewport.width)
    await confirm.getByRole("button", {name: "Cancel"}).click()
    await expect(confirm).toBeHidden()
    await expect(dialog.getByRole("button", {name: "Unpair"})).toBeFocused()
    await expect(row).toHaveCount(1)

    // Escape closes it too, and nothing is unpaired.
    await dialog.getByRole("button", {name: "Unpair"}).click()
    await expect(confirm).toBeVisible()
    await page.keyboard.press("Escape")
    await expect(confirm).toBeHidden()
    await expect(dialog).toBeVisible()
    await expect(row).toHaveCount(1)

    await dialog.getByRole("button", {name: "Unpair"}).click()
    await confirm.getByRole("button", {name: "Unpair"}).click()

    await expect(confirm).toBeHidden()
    await expect(dialog).toBeHidden()
    await expect(row).toHaveCount(0)
    await expect(page.locator("#account-agents [role=status]")).toHaveText(
      `${name} is unpaired. It will need a new code to pair again.`,
    )
    expect(errors).toEqual([])
  })
}

// Five tabs are wider than a 320 px phone, so the strip scrolls on its own, as the
// template's does, and the page itself never scrolls sideways.
test("on a 320 px phone, each account tab is a whole thumb wide, the open one is in view and the page never scrolls sideways", async ({page}) => {
  await page.setViewportSize({width: 320, height: 700})
  await signIn(page)
  await openAgents(page)

  const tabs = page.locator("#shell-tabs a")
  await expect(tabs).toHaveCount(5)
  for (const tab of await tabs.all()) {
    const box = (await tab.boundingBox())!
    expect.soft(box.width, await tab.innerText()).toBeGreaterThanOrEqual(44)
    expect.soft(box.height, await tab.innerText()).toBeGreaterThanOrEqual(44)
  }
  await expect(page.locator("#shell-tabs a[aria-current=page]")).toBeInViewport({ratio: 1})
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320)
})

// Once an agent pairs, the person is led to Your Keys on the Account page,
// where adding the agent to one of their Keys saves it at once and lists that
// Key first, with the agent under it. The agent's row then names the Key, and
// the page keeps to a 320 px screen.
test("an agent that pairs is put on the person's Key from Your Keys, and its row then names the Key", async ({page}) => {
  const fleet = "fleet_tech_classic"
  const me = "0x1111111111111111111111111111111111111111"
  prepareFleet(fleet)
  sellKey(fleet, me)
  const key = sellKey(fleet, me)
  const agent = newAgent()
  const name = `Keyed ${agent.slice(2, 8)}`
  const errors = await signIn(page)
  await openAgents(page)

  await page.locator("#account-agents").getByRole("button", {name: "Pair New Agent"}).click()
  await expect(page.locator("#shell-pairing")).toBeVisible()
  const box = page.locator("#shell-pairing-box")
  const next = page.locator("#shell-pairing-box-next")
  const radio = box.getByRole("radio", {name: "Hermes", exact: true})
  await radio.locator("xpath=ancestor::label").click()
  const message = box.locator("pre")
  await expect(message).toContainText(/Pairing code:\s*\S{12,}/)
  const before = (await next.boundingBox())!.height
  const [, code] = (await message.innerText()).match(/Pairing code:\s*(\S+)/)!
  useCode(agent, code, name)

  const assign = page.locator("#shell-pairing-box-assign-key")
  await expect(assign).toHaveText(`Assign ${name} a Key`)
  expect((await next.boundingBox())!.height).toBe(before)
  await expect(page.locator("#account-agents li", {hasText: name}).getByRole("link", {name: "Assign a Key"})).toBeVisible()

  await assign.click()
  await expect(page.locator("#shell-pairing")).toBeHidden()
  await expect(page).toHaveURL(url => url.pathname === "/account")
  const keys = page.locator(`#account-key-agents-${fleet}`)
  await keys.getByRole("combobox", {name: `Add an agent to Key ${key}`, exact: true}).selectOption({label: name})
  await expect(page.locator(`#account-key-agents-${fleet}-notice`)).toHaveText(`${name} is on Key ${key}.`)
  await expect(keys.locator(".key-gallery__key").first()).toHaveId(`account-key-agents-${fleet}-${key}`)
  await expect(page.locator(`#account-key-agents-${fleet}-${key}-agents`)).toContainText(name)

  await page.setViewportSize({width: 320, height: 640})
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320)
  await page.setViewportSize({width: 1280, height: 800})

  await openAgents(page)
  const row = page.locator("#account-agents li", {hasText: name})
  await expect(row.getByRole("link", {name: `Classic #1 Key ${key}`})).toHaveAttribute("href", `/classic/1/keys/${key}`)
  await expect(row.getByRole("link", {name: "Assign a Key"})).toHaveCount(0)
  expect(errors).toEqual([])
})

// Your Keys is a gallery: a Key holds several agents, each with its picture
// and name under the Key, and Keys with agents come first. Choosing an agent
// on another Key moves it, and its remove button takes it off. On a phone each
// Key is a row, its remove buttons are a full finger's height, and the page
// never scrolls sideways.
test("a Key holds several agents in the gallery, which moves and removes them", async ({page}) => {
  const fleet = "fleet_tech_classic"
  const me = "0x1111111111111111111111111111111111111111"
  prepareFleet(fleet)
  const first = sellKey(fleet, me)
  const second = sellKey(fleet, me)
  const [astra, bolt] = [newAgent(), newAgent()]
  const [nameA, nameB] = [`Astra ${astra.slice(2, 8)}`, `Bolt ${bolt.slice(2, 8)}`]
  pairPerson(astra, person, nameA)
  pairPerson(bolt, person, nameB)
  const errors = await signIn(page)
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const id = `account-key-agents-${fleet}`
  const gallery = page.locator(`#${id}`)
  const notice = page.locator(`#${id}-notice`)
  const add = (key: number) => gallery.getByRole("combobox", {name: `Add an agent to Key ${key}`, exact: true})
  const onKey = (key: number) => page.locator(`#${id}-${key}-agents li`)

  for (const name of [nameA, nameB]) {
    await add(second).selectOption({label: name})
    await expect(notice).toHaveText(`${name} is on Key ${second}.`)
  }
  await expect(onKey(second)).toHaveCount(2)
  await expect(onKey(second).locator("img.agent-picture")).toHaveCount(2)
  // Earlier walks may have left agents on other Keys of the person's.
  const order = () => gallery.locator(".key-gallery__key").evaluateAll(keys => keys.map(key => key.id))
  const before = (a: number, b: number) => async () => {
    const ids = await order()
    expect(ids.indexOf(`${id}-${a}`)).toBeLessThan(ids.indexOf(`${id}-${b}`))
  }
  await expect(before(second, first)).toPass()

  await add(first).selectOption({label: `${nameA} · Key ${second}`})
  await expect(notice).toHaveText(`${nameA} is on Key ${first}.`)
  await expect(onKey(first)).toHaveText([nameA])
  await expect(onKey(second)).toHaveText([nameB])

  for (const viewport of [{width: 390, height: 844}, {width: 320, height: 700}]) {
    await page.setViewportSize(viewport)
    // Measured as the page first draws at the new size: the Key Astra just went
    // to is still gliding to the front, and it lands as the window changes size.
    await page.evaluate(() => new Promise(requestAnimationFrame))
    const remove = gallery.getByRole("button", {name: `Take ${nameB} off Key ${second}`})
    expect((await remove.boundingBox())!.height).toBeGreaterThanOrEqual(44)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
  }

  await gallery.getByRole("button", {name: `Take ${nameB} off Key ${second}`}).click()
  await expect(notice).toHaveText(`${nameB} is off Key ${second}.`)
  await expect(page.locator(`#${id}-${second}-agents`)).toHaveCount(0)
  await expect(before(first, second)).toPass()
  expect(errors).toEqual([])
})

// Each agent on a Key shows the logo of the harness it paired on beside its
// picture, named for a screen reader; one paired as any other agent shows
// none. The logo leaves the row's height and its remove button where they
// were. Add agent's chevron stands in from the right border as far as its
// words stand in from the left, on a wide screen and on a phone.
test("each agent on a Key shows its harness's logo, and Add agent's chevron stands in as far as its words", async ({page}) => {
  const fleet = "fleet_tech_classic"
  const me = "0x1111111111111111111111111111111111111111"
  prepareFleet(fleet)
  const key = sellKey(fleet, me)
  const [muse, plain, spare] = [newAgent(), newAgent(), newAgent()]
  const [museName, plainName] = [`Muse ${muse.slice(2, 8)}`, `Plain ${plain.slice(2, 8)}`]
  pairPerson(muse, person, museName, "muse")
  pairPerson(plain, person, plainName, "other")
  // An agent left off the Key keeps Add agent on its card.
  pairPerson(spare, person, `Spare ${spare.slice(2, 8)}`, "codex")
  const errors = await signIn(page)
  await page.goto("/account")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()

  const id = `account-key-agents-${fleet}`
  const gallery = page.locator(`#${id}`)
  const add = gallery.getByRole("combobox", {name: `Add an agent to Key ${key}`, exact: true})
  for (const name of [museName, plainName]) {
    await add.selectOption({label: name})
    await expect(page.locator(`#${id}-notice`)).toHaveText(`${name} is on Key ${key}.`)
  }

  const row = (name: string) => page.locator(`#${id}-${key}-agents li`, {hasText: name})
  await expect(row(museName).getByRole("img", {name: "Muse", exact: true})).toBeVisible()
  await expect(row(plainName).getByRole("img")).toHaveCount(0)

  // The words start at the select's border and padding; the chevron drawn in
  // the browser's arrow's place ends as far in from the other side.
  const insets = () =>
    add.evaluate((select: HTMLSelectElement) => {
      const box = select.getBoundingClientRect()
      const style = getComputedStyle(select)
      const chevron = select.form!.querySelector("svg path")!.getBoundingClientRect()
      return {
        words: parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft),
        chevron: box.right - chevron.right,
        offCentre: Math.abs((chevron.top + chevron.bottom) / 2 - (box.top + box.bottom) / 2),
      }
    })

  for (const viewport of [{width: 1280, height: 800}, {width: 390, height: 844}]) {
    await page.setViewportSize(viewport)
    const {words, chevron, offCentre} = await insets()
    expect(Math.abs(chevron - words), `at ${viewport.width} px`).toBeLessThanOrEqual(2)
    expect(offCentre, `at ${viewport.width} px`).toBeLessThanOrEqual(1)

    const [withLogo, without] = [(await row(museName).boundingBox())!, (await row(plainName).boundingBox())!]
    expect(withLogo.height).toBe(without.height)
    const remove = (name: string) => gallery.getByRole("button", {name: `Take ${name} off Key ${key}`}).boundingBox()
    const [museRemove, plainRemove] = [(await remove(museName))!, (await remove(plainName))!]
    expect(museRemove.x).toBe(plainRemove.x)
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width)
  }
  expect(errors).toEqual([])
})
