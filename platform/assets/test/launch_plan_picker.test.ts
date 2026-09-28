import {expect, it} from "vitest"

import {LaunchPlanPicker} from "../js/hooks/launch_plan_picker"

// Vitest here runs without a document, so the launch form is the small
// surface the hook touches: its inputs by name and its change listener.
const planDigest = `0x${"c4".repeat(32)}`

const plan = {
  value: planDigest,
  dataset: {
    name: "Cascade Research",
    symbol: "CSR",
    description: "Research the fleet funds\nweekly",
    website: "https://example.test",
    image: "ipfs://cascade",
    floor: "0.000001",
    minimum: "250000.5",
  },
}

const noPlan = {value: "", dataset: {}}

function mountForm() {
  const inputs: Record<string, {value: string}> = Object.fromEntries(
    ["key", "name", "symbol", "description", "website", "image", "floor", "minimum", "digest"].map(name => [name, {value: ""}]),
  )
  inputs.key.value = "4"
  const select = {dataset: {launchPlans: ""}, options: [noPlan, plan], selectedIndex: 0}
  let listener: ((event: Event) => void) | undefined

  const root = {
    querySelector: (selector: string) => {
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
  const values = () => Object.fromEntries(Object.entries(inputs).map(([name, input]) => [name, input.value]))

  return {inputs, choose, values}
}

it("choosing a plan fills in its launch details, floor price and minimum raise and points the proposal to its version", () => {
  const form = mountForm()

  form.choose(1)

  expect(form.values()).toEqual({
    key: "4",
    name: "Cascade Research",
    symbol: "CSR",
    description: "Research the fleet funds\nweekly",
    website: "https://example.test",
    image: "ipfs://cascade",
    floor: "0.000001",
    minimum: "250000.5",
    digest: planDigest,
  })
})

it("choosing not to use a plan points the proposal nowhere and keeps the details as they are", () => {
  const form = mountForm()
  form.choose(1)
  form.inputs.name.value = "Cascade Research Two"

  form.choose(0)

  expect(form.values()).toMatchObject({name: "Cascade Research Two", symbol: "CSR", digest: ""})
})
