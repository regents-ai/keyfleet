import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {press, type Review} from "../js/hooks/onchain_steps"
import {
  forgetWalletDisconnected,
  replaceActiveEthereumWallet,
  type EthereumProvider,
} from "../js/wallet_actions/connected_wallet"

const signer = "0x1111111111111111111111111111111111111111"
const other = "0x2222222222222222222222222222222222222222"
const fleet = "0x3333333333333333333333333333333333333333"
const hash = `0x${"ab".repeat(32)}`

const review: Review = {
  id: "review-1",
  component_id: "buy-key-order",
  signer,
  chain: {chain_id: 1, name: "Ethereum", rpc_url: "https://eth.merkle.io"},
  steps: [{kind: "transaction", step: "buy", to: fleet, data: "0x1234", value: "0x0"}],
  inputs: {},
}

type Wallet = {
  provider: EthereumProvider
  sent: unknown[]
}

// A stand-in wallet: on `chainId`, holding `account`, answering each send with
// `answer` (a hash, or an error it throws).
function wallet({
  chainId = "0x1",
  account = signer,
  switches = true,
  answer = () => hash as unknown,
}: {chainId?: string; account?: string; switches?: boolean; answer?: () => unknown} = {}): Wallet {
  const sent: unknown[] = []
  let current = chainId
  const provider: EthereumProvider = {
    request: vi.fn(async ({method, params}: {method: string; params?: unknown}) => {
      switch (method) {
        case "eth_chainId":
          return current
        case "eth_accounts":
          return [account]
        case "wallet_switchEthereumChain":
          if (!switches) throw Object.assign(new Error("User rejected the switch"), {code: 4001})
          current = (params as [{chainId: string}])[0].chainId
          return null
        case "eth_sendTransaction":
          sent.push(params)
          return answer()
        default:
          throw new Error(`unexpected ${method}`)
      }
    }) as EthereumProvider["request"],
  }
  return {provider, sent}
}

function memoryStorage() {
  const values = new Map<string, string>()
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => void values.set(key, value),
    removeItem: (key: string) => void values.delete(key),
  }
}

beforeEach(() => {
  vi.stubGlobal("window", {localStorage: memoryStorage(), dispatchEvent: () => true})
  forgetWalletDisconnected()
  replaceActiveEthereumWallet(null)
})

afterEach(() => vi.unstubAllGlobals())

function pushes() {
  const pushed: [string, unknown][] = []
  return {pushed, push: (event: string, payload: unknown) => void pushed.push([event, payload])}
}

describe("a press sends the server's step from the wallet it was built for", () => {
  it("two presses in a row both reach eth_sendTransaction", async () => {
    const active = wallet()
    replaceActiveEthereumWallet({address: signer, provider: active.provider})
    const {pushed, push} = pushes()

    const answers = await Promise.all([press(review, "buy", push), press(review, "buy", push)])

    expect(answers).toEqual([{transaction_hash: hash}, {transaction_hash: hash}])
    expect(active.sent).toHaveLength(2)
    expect(active.sent[0]).toEqual([{from: signer, to: fleet, data: "0x1234", value: "0x0"}])
    expect(pushed).toEqual([
      ["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}],
      ["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}],
    ])
  })

  it("switches the wallet to the step's chain before sending", async () => {
    const active = wallet({chainId: "0x2105"})
    replaceActiveEthereumWallet({address: signer, provider: active.provider})
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(active.sent).toHaveLength(1)
    expect(pushed[0][0]).toBe("step_sent")
  })

  it("reports a decline in the wallet as wallet_declined", async () => {
    const active = wallet({answer: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
    replaceActiveEthereumWallet({address: signer, provider: active.provider})
    const {pushed, push} = pushes()

    expect(await press(review, "buy", push)).toEqual({reason: "wallet_declined"})
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_declined"}]])
  })

  it("sends nothing on the wrong chain when the wallet won't switch", async () => {
    const active = wallet({chainId: "0x2105", switches: false})
    replaceActiveEthereumWallet({address: signer, provider: active.provider})
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(active.sent).toHaveLength(0)
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "network_mismatch"}]])
  })

  it("sends nothing from a wallet the steps weren't built for", async () => {
    const active = wallet({account: other})
    replaceActiveEthereumWallet({address: other, provider: active.provider})
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(active.sent).toHaveLength(0)
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_unavailable"}]])
  })

  it("sends nothing when the wallet answers for another account", async () => {
    const active = wallet({account: other})
    replaceActiveEthereumWallet({address: signer, provider: active.provider})
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(active.sent).toHaveLength(0)
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_unavailable"}]])
  })

  it("sends nothing when no wallet is active", async () => {
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_unavailable"}]])
  })

  it("sends nothing for a step the server didn't build, or with no steps at all", async () => {
    const active = wallet()
    replaceActiveEthereumWallet({address: signer, provider: active.provider})
    const {pushed, push} = pushes()

    await press(review, "approve", push)
    await press(undefined, "buy", push)

    expect(active.sent).toHaveLength(0)
    expect(pushed).toEqual([
      ["step_failed", {step: "approve", reason: "step_unknown"}],
      ["step_failed", {step: "buy", reason: "step_unknown"}],
    ])
  })
})
