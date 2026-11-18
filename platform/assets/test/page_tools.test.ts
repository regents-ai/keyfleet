import {afterEach, expect, it, vi} from "vitest"

const asset = "0x3333333333333333333333333333333333333333"
const hash = `0x${"ab".repeat(32)}` as const

afterEach(() => vi.unstubAllGlobals())

it("offers Claim for all your Keys once for every fleet's group, and presses the fleet the agent names", async () => {
  const offered: ModelContextTool[] = []
  const registerTool = vi.fn(async (tool: ModelContextTool, {signal}: {signal: AbortSignal}) => {
    offered.push(tool)
    signal.addEventListener("abort", () => offered.splice(offered.indexOf(tool), 1))
  })
  vi.stubGlobal("document", {modelContext: {registerTool}})
  const {offerPageTool} = await import("../js/page_tools")

  // The Account page's Claim group for one fleet, with its one Claim button.
  const group = (fleet: string) => {
    const button = {dataset: {onchainStep: `claim-${asset}`}, disabled: false}
    const root = {dataset: {webmcpTool: "keys_claim_all", webmcpFleet: fleet}, querySelectorAll: () => [button]}
    const press = vi.fn(async () => ({transaction_hash: hash}))
    return {button, press, leaving: offerPageTool(root as unknown as HTMLElement, press)!}
  }
  const classic = group("fleet_tech_classic")
  const club = group("regents_club")

  expect(registerTool).toHaveBeenCalledTimes(1)
  expect(await offered[0].execute({fleet_id: "regents_club", asset}, {})).toMatchObject({ok: true, transaction_hash: hash})
  expect(club.press).toHaveBeenCalledWith(club.button, {})
  expect(classic.press).not.toHaveBeenCalled()

  classic.leaving.abort()
  expect(offered).toHaveLength(1)
  club.leaving.abort()
  expect(offered).toHaveLength(0)
})

// Costly failure: the agent's words go over the page's live socket whatever
// their length, and are drawn back into the page's boxes: longer than a box
// takes, the person's next keystroke is more than the socket reads, and the
// page closes it.
it("refuses a proposal longer than the page's own field takes, as the field counts it, and presses one that fits", async () => {
  const offered: ModelContextTool[] = []
  vi.stubGlobal("document", {modelContext: {registerTool: async (tool: ModelContextTool) => void offered.push(tool)}})
  const {offerPageTool} = await import("../js/page_tools")

  const button = {dataset: {onchainStep: "propose"}, disabled: false}
  const root = {dataset: {webmcpTool: "proposals_create"}, querySelectorAll: () => [button]}
  const press = vi.fn(async () => ({transaction_hash: hash}))
  const leaving = offerPageTool(root as unknown as HTMLElement, press)!
  const proposal = (text: string) => offered[0].execute({kind: "decision", key: "7", text}, {})

  // A box counts an emoji as two.
  for (const text of ["提".repeat(4001), "😀".repeat(2001), "😀".repeat(4000)]) {
    expect(await proposal(text)).toMatchObject({ok: false, error: {code: "invalid_input"}})
  }
  expect(press).not.toHaveBeenCalled()

  const fits = "😀".repeat(2000)
  expect(await proposal(fits)).toMatchObject({ok: true, transaction_hash: hash})
  expect(press).toHaveBeenCalledWith(button, {kind: "decision", key: "7", text: fits})
  leaving.abort()
})

it("answers a press the server refused to prepare with the note it sent", async () => {
  const offered: ModelContextTool[] = []
  vi.stubGlobal("document", {modelContext: {registerTool: async (tool: ModelContextTool) => void offered.push(tool)}})
  const {offerPageTool} = await import("../js/page_tools")

  const button = {dataset: {onchainStep: `claim-${asset}`}, disabled: false}
  const root = {dataset: {webmcpTool: "keys_claim"}, querySelectorAll: () => [button]}
  const press = vi.fn()
  const leaving = offerPageTool(root as unknown as HTMLElement, press)!

  const note = "The page's note."
  press.mockResolvedValueOnce({reason: "step_unknown", note})
  expect(await offered[0].execute({asset}, {})).toMatchObject({ok: false, error: {code: "step_unknown", message: note}})
  leaving.abort()
})
