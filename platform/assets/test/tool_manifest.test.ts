import {expect, it} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}
import {described} from "../js/tool_description"

type Entry = {
  name: string
  description: string
  scope: string
  authentication: string
  requires: string
  input_schema: {properties: {operation?: {enum: string[]}}}
}

const entries = manifest.tools as unknown as Entry[]

it("lets prepare_agent_request prepare every signed site tool, and nothing else", () => {
  const prepare = entries.find(entry => entry.name === "prepare_agent_request")
  const signed = entries
    .filter(entry => entry.scope === "site" && entry.authentication === "siwa_per_request")
    .map(entry => entry.name)

  expect([...(prepare?.input_schema.properties.operation?.enum ?? [])].sort()).toEqual(signed.sort())
})

it("ends every tool's description with what it needs, in the same words for the same need", () => {
  const closings: Record<string, RegExp> = {
    none: /[^.]\.$/,
    siwa: / Signed: prepare it with prepare_agent_request, .+ Works before pairing\.$/,
    siwa_and_pairing: / Signed: prepare it with prepare_agent_request, .+ Needs a pairing\.$/,
    siwa_and_pairing_and_product_rights: / Signed: prepare it with prepare_agent_request, .+ Needs a pairing, and in a fleet .+\.$/,
    wallet: / Needs sign-in and a wallet on your account open; .+\.$/,
  }

  for (const entry of entries) {
    expect(described(entry), entry.name).toMatch(closings[entry.requires])
    expect(described(entry), entry.name).not.toContain("  ")
  }
})
