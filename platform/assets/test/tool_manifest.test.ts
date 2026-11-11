import {expect, it} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}
import {described} from "../js/tool_description"

type Entry = {
  name: string
  description: string
  scope: string
  authentication: string
  requires: string
}

const entries = manifest.tools as unknown as Entry[]

it("ends every tool's description with what it needs, in the same words for the same need", () => {
  const closings: Record<string, RegExp> = {
    none: /[^.]\.$/,
    siwa: / Signed: your browser host signs it with your own agent key; pass only the input\. Works before pairing\.$/,
    siwa_and_pairing: / Signed: your browser host signs it with your own agent key; pass only the input\. Needs a pairing\.$/,
    siwa_and_pairing_and_product_rights: / Signed: your browser host signs it with your own agent key; pass only the input\. Needs a pairing, and in a fleet .+\.$/,
    wallet: / Needs sign-in and a wallet on your account open; .+\.$/,
  }

  for (const entry of entries) {
    expect(described(entry), entry.name).toMatch(closings[entry.requires])
    expect(described(entry), entry.name).not.toContain("  ")
  }
})
