import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {asksServer, OnchainSteps, press, type Review} from "../js/hooks/onchain_steps"
import {
  forgetWalletDisconnected,
  replaceActiveEthereumWallet,
  type EthereumProvider,
  type SwitchChain,
} from "../js/wallet_actions/connected_wallet"

const signer = "0x1111111111111111111111111111111111111111"
const fleet = "0x3333333333333333333333333333333333333333"
const hash = `0x${"ab".repeat(32)}`

const review: Review = {
  id: "review-1",
  component_id: "buy-key-order",
  signer,
  chain: {chain_id: 8453},
  steps: [{kind: "transaction", step: "buy", to: fleet, data: "0x1234", value: "0x0"}],
  inputs: {},
}

type Wallet = {
  provider: EthereumProvider
  switchChain: SwitchChain
  sent: unknown[]
}

// A stand-in wallet: on `chainId`, moved by its own switch, answering each
// send with `answer` (a hash, or an error it throws).
function wallet({
  chainId = 8453,
  answer = () => hash as unknown,
}: {chainId?: number; answer?: () => unknown} = {}): Wallet {
  const sent: unknown[] = []
  let current = chainId
  const provider: EthereumProvider = {
    request: vi.fn(async ({method, params}: {method: string; params?: unknown}) => {
      switch (method) {
        case "eth_chainId":
          return `0x${current.toString(16)}`
        case "eth_sendTransaction":
          sent.push(params)
          return answer()
        default:
          throw new Error(`unexpected ${method}`)
      }
    }) as EthereumProvider["request"],
  }
  const switchChain: SwitchChain = async wanted => {
    current = wanted
  }
  return {provider, switchChain, sent}
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

describe("a press sends the server's step through the active wallet", () => {
  it("two presses in a row both reach eth_sendTransaction", async () => {
    const active = wallet()
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
    const {pushed, push} = pushes()

    const answers = await Promise.all([press(review, "buy", push), press(review, "buy", push)])

    expect(answers).toEqual([{transaction_hash: hash}, {transaction_hash: hash}])
    expect(active.sent).toHaveLength(2)
    expect(active.sent[0]).toEqual([{from: signer, to: fleet, data: "0x1234", value: "0x0", chainId: "0x2105"}])
    expect(pushed).toEqual([
      ["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}],
      ["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}],
    ])
  })

  it("switches the wallet to the step's chain before sending", async () => {
    const active = wallet({chainId: 1})
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(active.sent).toHaveLength(1)
    expect(pushed[0][0]).toBe("step_sent")
  })

  it("reports a decline in the wallet as wallet_declined", async () => {
    const active = wallet({answer: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
    const {pushed, push} = pushes()

    expect(await press(review, "buy", push)).toEqual({reason: "wallet_declined"})
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_declined"}]])
  })

  // A press answers from what the wallet did, at once, whatever becomes of its
  // report: offline, on a page left behind, or never answered at all.
  it("answers at once, without waiting on its report to the server", async () => {
    const active = wallet({answer: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
    const unanswered = () => new Promise<never>(() => {})

    const answered = await Promise.race([
      press(review, "buy", unanswered),
      new Promise(resolve => setTimeout(() => resolve("still waiting"), 200)),
    ])

    expect(answered).toEqual({reason: "wallet_declined"})
  })

  it("sends nothing when no wallet is active", async () => {
    const {pushed, push} = pushes()

    await press(review, "buy", push)

    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_unavailable"}]])
  })

  it("sends nothing for a step the server didn't build, or with no steps at all", async () => {
    const active = wallet()
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
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

describe("a press asks the server for its review when the page's won't do", () => {
  const withInputs: Review = {...review, inputs: {days: "30"}}

  it("asks when no review has arrived yet, as for a button that has just appeared", () => {
    expect(asksServer(undefined, "buy", {})).toBe(true)
  })

  it("asks when the review has no such step yet", () => {
    expect(asksServer(review, "renew-0xdddddddddddddddddddddddddddddddddddddddd", {})).toBe(true)
  })

  it("asks when the form on screen differs from what the review was built from", () => {
    expect(asksServer(withInputs, "buy", {days: "45"})).toBe(true)
  })

  it("sends straight away when the review has the step and matches the form", () => {
    expect(asksServer(review, "buy", {})).toBe(false)
    expect(asksServer(withInputs, "buy", {days: "30"})).toBe(false)
  })
})

// A form field, as the hook tells one from other inputs.
class Input {
  type = "text"
  constructor(
    public value: string,
    public dataset: Record<string, string>,
  ) {}
}

// The hook on a group whose form shows `form`, with the server answering an ask
// for steps with `reply`.
function group(form: Record<string, string>, reply: (payload: unknown) => unknown) {
  const pushed: [string, unknown][] = []
  const handlers: Record<string, (payload: unknown) => void> = {}
  let clicked: ((event: unknown) => void) | undefined
  const button = {dataset: {onchainStep: "buy"} as Record<string, string>, closest: () => button}
  const fields = Object.entries(form).map(([name, value]) => new Input(value, {onchainInput: name}))
  const el = {
    id: "buy-key-order",
    addEventListener: (_type: string, listener: (event: unknown) => void) => {
      clicked = listener
    },
    removeEventListener: () => undefined,
    contains: () => true,
    hasAttribute: () => false,
    querySelectorAll: () => fields,
    querySelector: () => null,
  }
  const hook = {
    el,
    handleEvent: (event: string, handler: (payload: unknown) => void) => {
      handlers[event] = handler
    },
    pushEventTo: async (_target: unknown, event: string, payload: unknown) => {
      pushed.push([event, payload])
      return [{status: "fulfilled", value: {reply: event === "prepare_and_send" ? reply(payload) : {}}}]
    },
  }
  OnchainSteps.mounted!.call(hook)

  return {
    asked: () => pushed.filter(([event]) => event === "prepare_and_send"),
    pushed,
    held: (steps: Review) => handlers["onchain-steps:review"]({component_id: el.id, review: steps}),
    rejoined: () => OnchainSteps.reconnected!.call(hook),
    press: () => clicked!({target: button}),
  }
}

// Invariant: a press that asks the server for its steps names the open wallet,
// so a page that has just joined again, whose server has not yet heard which
// wallet is open, still gets steps back and the press reaches the wallet.
describe("a press that asks the server for its steps names the open wallet", () => {
  beforeEach(() => {
    vi.stubGlobal("window", Object.assign(new EventTarget(), {localStorage: memoryStorage()}))
    vi.stubGlobal("document", {})
    vi.stubGlobal("HTMLInputElement", Input)
  })

  it("after the page joins again, and sends the steps that come back", async () => {
    const active = wallet()
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
    const page = group({}, () => ({review, send: "buy"}))
    page.held(review)
    page.rejoined()

    page.press()

    await vi.waitFor(() => expect(active.sent).toHaveLength(1))
    expect(page.asked()).toEqual([["prepare_and_send", {form: {}, step: "buy", address: signer}]])
    await vi.waitFor(() =>
      expect(page.pushed).toContainEqual(["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}]),
    )
  })

  it("with the form on screen when the held steps were built from another", async () => {
    const active = wallet()
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain: active.switchChain})
    const page = group({days: "45"}, () => ({review: {...review, id: "review-45", inputs: {days: "45"}}, send: "buy"}))
    page.held({...review, inputs: {days: "30"}})

    page.press()

    await vi.waitFor(() => expect(active.sent).toHaveLength(1))
    expect(page.asked()).toEqual([["prepare_and_send", {form: {days: "45"}, step: "buy", address: signer}]])
    await vi.waitFor(() =>
      expect(page.pushed).toContainEqual(["step_sent", {review_id: "review-45", step: "buy", transaction_hash: hash}]),
    )
  })
})
