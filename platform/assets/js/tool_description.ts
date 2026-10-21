// A browser tool's description as the page registers it: what the tool does,
// from priv/tool_manifest.json, then what it needs, in the same words for every
// tool with the same requirement.

const signed = "Signed: prepare it with prepare_agent_request, sign it with your SIWA signer, then pass input, request and proof."

const needs: Record<string, string> = {
  none: "",
  siwa: `${signed} Works before pairing.`,
  siwa_and_pairing: `${signed} Needs a pairing.`,
  siwa_and_pairing_and_product_rights: `${signed} Needs a pairing, and in a fleet a Key, a shard of one or a person who holds one.`,
  wallet: "Needs sign-in and a wallet on your account open; the wallet asks the person to approve the transaction, and the network fee is paid from it.",
}

export function described(entry: {description: string; requires: string}): string {
  return [entry.description, needs[entry.requires]].filter(Boolean).join(" ")
}
