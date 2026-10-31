// A browser tool's description as the page registers it: what the tool does,
// from priv/tool_manifest.json, then what it needs, in the same words for every
// tool with the same requirement.

const signed = "Signed: your browser host signs it with your own agent key; pass only the input."

const needs: Record<string, string> = {
  none: "",
  siwa: `${signed} Works before pairing.`,
  siwa_and_pairing: `${signed} Needs a pairing.`,
  siwa_and_pairing_and_product_rights: `${signed} Needs a pairing, and in a fleet a Key, a shard of one or a person who holds one.`,
  wallet: "Needs sign-in and a wallet on your account open; the wallet asks the person to approve and pays the network fee. Answers the transaction hash, or the signature when the wallet only signs.",
}

export function described(entry: {description: string; requires: string}): string {
  return [entry.description, needs[entry.requires]].filter(Boolean).join(" ")
}
