import {expect, it} from "vitest"

import {press, type Review} from "../js/hooks/onchain_steps"
import {replaceActiveEthereumWallet, type SwitchChain} from "../js/wallet_actions/connected_wallet"
import {sendStep, signStep, type SignatureStep, type TransactionStep} from "../js/wallet_actions/send_step"

const base = 8453
const chain = {chain_id: base}
const signer: `0x${string}` = "0x3333333333333333333333333333333333333333"
const step: TransactionStep = {
  kind: "transaction",
  step: "buy",
  to: "0x1111111111111111111111111111111111111111",
  data: "0x",
  value: "0x0",
}
const signature: SignatureStep = {kind: "signature", step: "sign", typed_data: {}}
const hash = `0x${"ab".repeat(32)}`
const signed = `0x${"cd".repeat(65)}`
const review: Review = {id: "r1", component_id: "c1", signer, chain, steps: [step, signature], inputs: {}}

// A wallet app open on `account` and on network `on`, which moves only through
// Privy's switch (`switching` says what that switch does with each ask), and
// remembers what it was asked.
function walletOn(account: string, {on = base, switching = (wanted: number) => wanted as number | Error} = {}) {
  let current = on
  const sent: unknown[] = []
  const switches: number[] = []
  const provider = {
    request: async ({method, params}: {method: string; params?: unknown[]}) => {
      if (method === "eth_chainId") return `0x${current.toString(16)}`
      if (method === "eth_accounts") return [account]
      if (method === "eth_sendTransaction") {
        sent.push(params?.[0])
        return hash
      }
      if (method === "eth_signTypedData_v4") {
        sent.push(params)
        return signed
      }
      throw new Error(`unexpected ${method}`)
    },
  }
  const switchChain: SwitchChain = async wanted => {
    switches.push(wanted)
    const answer = switching(wanted)
    if (answer instanceof Error) throw answer
    current = answer
  }
  return {sent, switches, selected: {address: account, provider, switchChain}}
}

function walletError(code: number, message: string): Error & {code: number} {
  return Object.assign(new Error(message), {code})
}

// Presses `name` with `wallet` as Privy's active wallet: what the press
// answered, and what the hook reported.
async function pressWith(wallet: ReturnType<typeof walletOn>, name: string) {
  const reports: unknown[] = []
  replaceActiveEthereumWallet(wallet.selected)
  try {
    const pressed = await press(review, name, (event, payload) => reports.push([event, payload]))
    return {pressed, reports}
  } finally {
    replaceActiveEthereumWallet(null)
  }
}

// Invariant: every press reaches the active wallet. The page never compares
// the wallet's account with the signer the server built the step for; the
// wallet receives the step and decides.
it("sends and signs through the active wallet when it answers for another account", async () => {
  for (const name of ["buy", "sign"]) {
    const wallet = walletOn("0x2222222222222222222222222222222222222222")
    const {pressed, reports} = await pressWith(wallet, name)

    expect(pressed).toEqual(name === "buy" ? {transaction_hash: hash} : {signature: signed})
    expect(reports).toEqual([[name === "buy" ? "step_sent" : "step_signed", {review_id: review.id, step: name, ...pressed}]])
    expect(wallet.sent).toHaveLength(1)
  }
})

// Invariant: a wallet on another network is asked to switch to the step's on
// every press, and once that switch resolves the same press sends or signs,
// with no second read of the chain standing between them. A wallet already on
// the step's network is never asked.
it("asks the switch on every press off Base, then sends", async () => {
  for (const name of ["buy", "sign"]) {
    const there = walletOn(signer)
    await pressWith(there, name)
    expect(there.switches).toEqual([])
    expect(there.sent).toHaveLength(1)

    // The switch resolves, yet the wallet goes on naming another network: the
    // send still goes out, and the next press asks again.
    const elsewhere = walletOn(signer, {on: 1, switching: () => 1})
    for (let n = 1; n <= 3; n++) {
      const {pressed} = await pressWith(elsewhere, name)
      expect(pressed).not.toHaveProperty("reason")
      expect(elsewhere.sent).toHaveLength(n)
    }
    expect(elsewhere.switches).toEqual([base, base, base])
  }
})

// Invariant: when the wallet declines the switch (4001, however it wraps it) or
// the switch fails any other way, that press sends nothing and says which, and
// the next press asks the wallet to switch again and sends once it does.
it("sends nothing when the switch is declined or fails, and the next press asks again", async () => {
  const cases: Array<[string, Error]> = [
    ["switch_declined", walletError(4001, "User rejected the request.")],
    ["switch_declined", Object.assign(new Error("wrapped"), {cause: walletError(4001, "rejected")})],
    ["network_mismatch", walletError(4902, "Unrecognized chain ID")],
    ["network_mismatch", new Error("Unsupported chainId: 8453")],
    ["network_mismatch", walletError(-32603, "Internal error")],
  ]

  for (const [reason, refusal] of cases) {
    for (const name of ["buy", "sign"]) {
      let refuses = true
      const wallet = walletOn(signer, {on: 1, switching: wanted => (refuses ? refusal : wanted)})

      const first = await pressWith(wallet, name)
      expect(first.pressed).toEqual({reason})
      expect(first.reports).toEqual([["step_failed", {step: name, reason}]])
      expect(wallet.sent).toEqual([])

      refuses = false
      const next = await pressWith(wallet, name)
      expect(next.pressed).not.toHaveProperty("reason")
      expect(wallet.switches).toEqual([base, base])
      expect(wallet.sent).toHaveLength(1)
    }
  }
})

it("sends the server's step as built, from its signer and for its chain", async () => {
  const {sent, selected} = walletOn(signer)

  await expect(sendStep(chain, signer, step, selected, () => undefined)).resolves.toBe(hash)
  await expect(signStep(chain, signer, signature, selected, () => undefined)).resolves.toBe(signed)
  expect(sent).toEqual([
    {from: signer, to: step.to, data: "0x", value: "0x0", chainId: "0x2105"},
    [signer, "{}"],
  ])
})

it("sends nothing with no active wallet", async () => {
  const reports: unknown[] = []

  await expect(press(review, "buy", (event, payload) => reports.push([event, payload])))
    .resolves.toEqual({reason: "wallet_unavailable"})
  expect(reports).toEqual([["step_failed", {step: "buy", reason: "wallet_unavailable"}]])
})
