import {expect, it} from "vitest"
import {decodeFunctionData, zeroHash} from "viem"

import {LaunchPlanPicker, noPlanWords} from "../js/hooks/launch_plan_picker"
import {encode, readAction, votesAbi} from "../js/wallet_actions/fleet_action"

// Vitest here runs without a document, so the launch form is the small
// surface the hook touches: its inputs by name, its status line and its
// change listener.
const planDigest = `0x${"c4".repeat(32)}`

const plan = {
  value: planDigest,
  dataset: {
    title: "Cascade Research",
    version: "3",
    name: "Cascade Research",
    symbol: "CSR",
    description: "Research the fleet funds\nweekly",
    website: "https://example.test",
    image: "ipfs://cascade",
    raise: "250000.5",
  },
}

const noPlan = {value: "", dataset: {}}

function mountForm() {
  const inputs: Record<string, {value: string}> = Object.fromEntries(
    ["key", "name", "symbol", "description", "website", "image", "raise", "until", "digest"].map(name => [
      name,
      {value: ""},
    ]),
  )
  inputs.key.value = "4"
  inputs.until.value = "2026-10-23T18:30"
  const status = {textContent: noPlanWords}
  const select = {dataset: {launchPlans: ""}, options: [noPlan, plan], selectedIndex: 0}
  let listener: ((event: Event) => void) | undefined

  const root = {
    querySelector: (selector: string) => {
      if (selector === "[data-launch-plan-status]") return status
      const name = /^\[name="(\w+)"\]$/.exec(selector)?.[1]
      return name ? inputs[name] : null
    },
    addEventListener: (_name: string, handler: (event: Event) => void) => (listener = handler),
    removeEventListener: () => (listener = undefined),
  }
  LaunchPlanPicker.mounted!.call({el: root})

  const choose = (index: number) => {
    select.selectedIndex = index
    listener!({target: select} as unknown as Event)
  }
  // What the Propose button sends with the form as it stands.
  const proposal = () =>
    decodeFunctionData({abi: votesAbi, data: encode(readAction("propose_launch", {}, name => inputs[name].value))})

  return {inputs, status, choose, proposal}
}

it("choosing a plan fills in its six launch details and points the proposal to its version", () => {
  const form = mountForm()

  form.choose(1)

  expect(form.status.textContent).toBe("This proposal will point to Cascade Research, version 3.")
  expect(form.proposal().args[1]).toMatchObject({
    name: "Cascade Research",
    symbol: "CSR",
    description: "Research the fleet funds\nweekly",
    website: "https://example.test",
    image: "ipfs://cascade",
    requiredRegentRaised: 250_000_500_000_000_000_000_000n,
    narrativeDigest: planDigest,
  })
})

it("choosing not to use a plan points the proposal nowhere and keeps the details as they are", () => {
  const form = mountForm()
  form.choose(1)
  form.inputs.name.value = "Cascade Research Two"

  form.choose(0)

  expect(form.status.textContent).toBe(noPlanWords)
  expect(form.inputs.digest.value).toBe("")
  expect(form.proposal().args[1]).toMatchObject({name: "Cascade Research Two", narrativeDigest: zeroHash})
})
