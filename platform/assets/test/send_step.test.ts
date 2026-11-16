// A wallet on another network is moved by its own switch (Privy's, which knows
// how each wallet app adds a network) before anything is sent or signed.
import {expect, it} from "vitest"

import {press, type Review} from "../js/hooks/onchain_steps"
import {replaceActiveEthereumWallet, type SwitchChain} from "../js/wallet_actions/connected_wallet"
import {NothingSent, sendStep, signStep, type SignatureStep, type TransactionStep} from "../js/wallet_actions/send_step"

const base = 8453
const chain = {chain_id: base}
const signer = "0x3333333333333333333333333333333333333333"
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

// A wallet app on `on`, which moves only through Privy's switch (`switching`
// says what that switch does with each ask), and remembers what it was asked.
function walletOn({on = base, switching = (wanted: number) => wanted as number | Error} = {}) {
  let current = on
  const sent: unknown[] = []
  const switches: number[] = []
  const provider = {
    request: async ({method, params}: {method: string; params?: unknown[]}) => {
      if (method === "eth_chainId") return `0x${current.toString(16)}`
      if (method === "eth_accounts") return [signer]
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
  return {sent, switches, selected: {address: signer, provider, switchChain}}
}

function walletError(code: number, message: string): Error & {code: number} {
  return Object.assign(new Error(message), {code})
}

type Selected = ReturnType<typeof walletOn>["selected"]

// Invariant: a wallet already on the step's chain is never asked to switch; one
// on another network is asked once, then sends or signs.
it("asks the wallet's own switch only when the wallet is on another network", async () => {
  for (const send of [
    (selected: Selected) => sendStep(chain, signer, step, () => selected, () => undefined),
    (selected: Selected) => signStep(chain, signer, signature, () => selected, () => undefined),
  ]) {
    const there = walletOn()
    await send(there.selected)
    expect(there.switches).toEqual([])
    expect(there.sent).toHaveLength(1)

    const elsewhere = walletOn({on: 1})
    await send(elsewhere.selected)
    expect(elsewhere.switches).toEqual([base])
    expect(elsewhere.sent).toHaveLength(1)
  }
})

// Invariant: nothing remembers a refusal; every press while the wallet stays
// elsewhere asks for the switch again.
it("asks the switch again on every press while the wallet stays elsewhere", async () => {
  const {sent, switches, selected} = walletOn({on: 1, switching: () => walletError(4001, "rejected")})

  for (let press = 0; press < 3; press++) {
    await expect(sendStep(chain, signer, step, () => selected, () => undefined)).rejects.toBeInstanceOf(NothingSent)
  }
  expect(switches).toEqual([base, base, base])
  expect(sent).toEqual([])
})

// Invariant: nothing reaches the wallet's send while it is off the step's chain,
// and the press reports which: the person said no to the switch (4001, however
// the wallet wraps it), or the wallet could not switch or is still elsewhere.
it("sends nothing and reports a declined switch apart from a failed one", async () => {
  const review: Review = {id: "r1", component_id: "c1", signer, chain, steps: [step, signature], inputs: {}}
  const cases: Array<[string, (wanted: number) => number | Error]> = [
    ["switch_declined", () => walletError(4001, "User rejected the request.")],
    ["switch_declined", () => Object.assign(new Error("wrapped"), {cause: walletError(4001, "rejected")})],
    ["network_mismatch", () => walletError(4902, "Unrecognized chain ID")],
    ["network_mismatch", () => new Error("Unsupported chainId: 8453")],
    ["network_mismatch", () => walletError(-32603, "Internal error")],
    // The switch answered, but the wallet still reports another network.
    ["network_mismatch", () => 1],
  ]

  try {
    for (const [reason, switching] of cases) {
      for (const name of ["buy", "sign"]) {
        const wallet = walletOn({on: 1, switching})
        const reports: unknown[] = []
        replaceActiveEthereumWallet(wallet.selected)

        await expect(press(review, name, (event, payload) => reports.push([event, payload])))
          .resolves.toEqual({reason})
        expect(reports).toEqual([["step_failed", {step: name, reason}]])
        expect(wallet.switches).toEqual([base])
        expect(wallet.sent).toEqual([])
      }
    }
  } finally {
    replaceActiveEthereumWallet(null)
  }
})
