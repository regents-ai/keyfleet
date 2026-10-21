import {expect, it} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

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
