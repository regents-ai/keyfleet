import {expect, it} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}
import {described} from "../js/public_tool_list"

type Entry = {
  name: string
  scope: string
  authentication: string
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

it("ends every signed tool's description with how to sign it and what it needs", () => {
  const signed = entries.filter(entry => entry.authentication === "siwa_per_request") as unknown as Parameters<typeof described>[0][]

  for (const entry of signed) {
    expect(described(entry)).toMatch(/ Signed: prepare it with prepare_agent_request, .+ (Works before pairing|Needs a pairing[^.]*)\.$/)
  }
})
