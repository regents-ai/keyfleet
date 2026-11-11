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
