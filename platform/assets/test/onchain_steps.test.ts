import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

vi.mock("../js/visit_log", () => ({report: vi.fn()}))

import {asksServer, OnchainSteps, press, type Review} from "../js/hooks/onchain_steps"
import {report} from "../js/visit_log"
import {
  forgetWalletDisconnected,
  replaceActiveEthereumWallet,
  type EthereumProvider,
  type SelectedWallet,
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
  selected: SelectedWallet
  provider: EthereumProvider
  switchChain: SwitchChain
  sent: unknown[]
}

// A stand-in wallet holding `address`: on `chainId`, moved by its own switch,
// answering each send with `answer` (a hash, or an error it throws).
function wallet({
  address = signer,
  chainId = 8453,
  answer = () => hash as unknown,
}: {address?: string; chainId?: number; answer?: () => unknown} = {}): Wallet {
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
  return {selected: {address, provider, switchChain}, provider, switchChain, sent}
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
  vi.mocked(report).mockClear()
})

afterEach(() => vi.unstubAllGlobals())

function pushes() {
  const pushed: [string, unknown][] = []
  return {pushed, push: (event: string, payload: unknown) => void pushed.push([event, payload])}
}

describe("a press sends the server's step through the wallet open at the press", () => {
  it("two presses in a row both reach eth_sendTransaction", async () => {
    const active = wallet()
    const {pushed, push} = pushes()

    const answers = await Promise.all([press(review, "buy", active.selected, push), press(review, "buy", active.selected, push)])

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
    const {pushed, push} = pushes()

    await press(review, "buy", active.selected, push)

    expect(active.sent).toHaveLength(1)
    expect(pushed[0][0]).toBe("step_sent")
  })

  it("reports a decline in the wallet as wallet_declined", async () => {
    const active = wallet({answer: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
    const {pushed, push} = pushes()

    expect(await press(review, "buy", active.selected, push)).toEqual({reason: "wallet_declined"})
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_declined"}]])
  })

  // A press answers from what the wallet did, at once, whatever becomes of its
  // report: offline, on a page left behind, or never answered at all.
  it("answers at once, without waiting on its report to the server", async () => {
    const active = wallet({answer: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
    const unanswered = () => new Promise<never>(() => {})

    const answered = await Promise.race([
      press(review, "buy", active.selected, unanswered),
      new Promise(resolve => setTimeout(() => resolve("still waiting"), 200)),
    ])

    expect(answered).toEqual({reason: "wallet_declined"})
  })

  it("sends nothing when no wallet is open", async () => {
    const {pushed, push} = pushes()

    await press(review, "buy", null, push)

    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_unavailable"}]])
  })

  it("sends nothing for a step the server didn't build, or with no steps at all", async () => {
    const active = wallet()
    const {pushed, push} = pushes()

    await press(review, "approve", active.selected, push)
    await press(undefined, "buy", active.selected, push)

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

// A server answer that never came back: the page lost its connection.
const unreached = Symbol("unreached")

function answered(answer: unknown) {
  return [
    answer === unreached
      ? {status: "rejected", reason: new Error("The page lost its connection")}
      : {status: "fulfilled", value: {reply: answer}},
  ]
}

// The hook on a group with no form fields, with the server answering an ask for
// steps with `reply`.
function group(reply: (payload: {address?: string}) => unknown) {
  const pushed: [string, unknown][] = []
  const handlers: Record<string, (payload: unknown) => void> = {}
  let clicked: ((event: unknown) => void) | undefined
  const button = {dataset: {onchainStep: "buy"} as Record<string, string>, closest: () => button}
  const lostLine = {hidden: true}
  const el = {
    id: "buy-key-order",
    addEventListener: (_type: string, listener: (event: unknown) => void) => {
      clicked = listener
    },
    removeEventListener: () => undefined,
    contains: () => true,
    hasAttribute: () => false,
    querySelectorAll: () => [],
    querySelector: (selector: string) => (selector === "[data-onchain-lost]" ? lostLine : null),
  }
  const hook = {
    el,
    handleEvent: (event: string, handler: (payload: unknown) => void) => {
      handlers[event] = handler
    },
    pushEventTo: async (_target: unknown, event: string, payload: unknown) => {
      pushed.push([event, payload])
      return answered(event === "prepare_and_send" ? reply(payload as {address?: string}) : {})
    },
  }
  OnchainSteps.mounted!.call(hook)

  return {
    pushed,
    lostLine,
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
  })

  it("after the page joins again, and sends the steps that come back", async () => {
    const active = wallet()
    replaceActiveEthereumWallet(active.selected)
    // A server that has not heard which wallet is open builds steps only for
    // the wallet the ask names, and refuses an ask that names none.
    const page = group(({address}) => (address === signer ? {review, send: "buy"} : {note: "Open your wallet."}))
    page.held(review)
    page.rejoined()

    page.press()

    await vi.waitFor(() =>
      expect(page.pushed).toContainEqual(["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}]),
    )
    expect(active.sent).toHaveLength(1)
  })
})

// Invariant: the wallet open at the press is the one that acts for it. A press
// that asks the server for its steps sends them through that wallet, even when
// another wallet is open by the time they arrive.
describe("a press goes to the wallet open when it was pressed", () => {
  beforeEach(() => {
    vi.stubGlobal("window", Object.assign(new EventTarget(), {localStorage: memoryStorage()}))
    vi.stubGlobal("document", {})
  })

  it("sends the steps it asked for through that wallet, when another opens meanwhile", async () => {
    const pressed = wallet()
    const other = wallet({address: "0x2222222222222222222222222222222222222222"})
    replaceActiveEthereumWallet(pressed.selected)
    // The person opens another wallet while the server builds the steps.
    const page = group(() => {
      replaceActiveEthereumWallet(other.selected)
      return {review, send: "buy"}
    })

    page.press()

    await vi.waitFor(() =>
      expect(page.pushed).toContainEqual(["step_sent", {review_id: "review-1", step: "buy", transaction_hash: hash}]),
    )
    expect(pressed.sent).toHaveLength(1)
    expect(other.sent).toEqual([])
  })
})

const proposeReview: Review = {
  ...review,
  id: "review-agent",
  component_id: "propose-action",
  steps: [{kind: "transaction", step: "propose", to: fleet, data: "0x5678", value: "0x0"}],
  inputs: {kind: "decision", key: "7", text: "The agent's words"},
}

// The person's own form on the proposal group, and the steps the page holds
// for it.
const theirs = {kind: "decision", key: "8", text: "The person's words"}
const theirReview: Review = {...proposeReview, id: "review-person", inputs: theirs}

// Each proposal group's leaving, run after its test whatever became of it, so
// a test that fails leaves no tool offered for the next.
const leaving: (() => void)[] = []

// The hook on the proposal group, offering its browser agent's tool, with the
// person's form holding Key 8 and its Propose button held back for it unless
// `held` is false, and the server answering an agent's ask with `reply`.
function proposalGroup(reply: () => unknown, held = true) {
  const pushed: [string, unknown][] = []
  const offered: ModelContextTool[] = []
  const handlers: Record<string, (payload: unknown) => void> = {}
  vi.stubGlobal("document", {modelContext: {registerTool: async (tool: ModelContextTool) => void offered.push(tool)}})
  const button = {dataset: {onchainStep: "propose"}, disabled: held}
  const fields = Object.entries(theirs).map(([name, value]) => ({dataset: {onchainInput: name}, value}))
  const lostLine = {hidden: true}
  const el = {
    id: "propose-action",
    dataset: {webmcpTool: "proposals_create"},
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    hasAttribute: () => false,
    querySelectorAll: (selector: string) => (selector.startsWith("button") ? [button] : fields),
    querySelector: (selector: string) => (selector === "[data-onchain-lost]" ? lostLine : null),
  }
  const hook = {
    el,
    handleEvent: (event: string, handler: (payload: unknown) => void) => {
      handlers[event] = handler
    },
    pushEventTo: async (_target: unknown, event: string, payload: unknown) => {
      pushed.push([event, payload])
      return answered(event === "prepare_for_agent" ? reply() : {})
    },
  }
  OnchainSteps.mounted!.call(hook)
  leaving.push(() => OnchainSteps.destroyed!.call(hook))

  return {
    pushed,
    lostLine,
    // What the press told the server, leaving out the wallet the page reports on its own.
    told: () => pushed.filter(([event]) => event !== "onchain_active_wallet"),
    held: (steps: Review) => handlers["onchain-steps:review"]({component_id: el.id, review: steps}),
    call: async (input: Record<string, string>) => {
      await vi.waitFor(() => expect(offered).toHaveLength(1))
      return offered[0].execute(input, {})
    },
  }
}

// Invariant: the browser agent's press is built and judged from the agent's
// values over the form's, by the server for that press alone, whatever the
// person's own button shows: the person's form never becomes the agent's.
describe("a browser agent's press is judged on its own values", () => {
  beforeEach(() => {
    vi.stubGlobal("window", Object.assign(new EventTarget(), {localStorage: memoryStorage()}))
    vi.stubGlobal("HTMLInputElement", class {})
  })

  afterEach(() => leaving.splice(0).forEach(leave => leave()))

  it("asks for steps built from its values while the person's button is held back, and sends them", async () => {
    const active = wallet()
    replaceActiveEthereumWallet(active.selected)
    const page = proposalGroup(() => ({review: proposeReview, send: "propose"}))

    const answer = await page.call({kind: "decision", key: "7", text: "The agent's words"})

    expect(answer).toMatchObject({ok: true, transaction_hash: hash})
    expect(active.sent).toHaveLength(1)
    expect(page.pushed).toContainEqual([
      "prepare_for_agent",
      {form: {kind: "decision", key: "7", text: "The agent's words"}, step: "propose", address: signer},
    ])
    expect(page.pushed.map(([event]) => event)).not.toContain("step_pressed")
  })

  it("answers the server's words for a press of its values the chain's state holds back, and asks no wallet", async () => {
    const active = wallet()
    replaceActiveEthereumWallet(active.selected)
    const page = proposalGroup(() => ({reason: "blocked", cause: "values", note: "Not your Key"}))

    const answer = await page.call({kind: "decision", key: "9", text: "The agent's words"})

    expect(answer).toMatchObject({ok: false, error: {code: "blocked", message: "Not your Key"}})
    expect(active.sent).toEqual([])
  })

  // Costly failure: the agent's values are the person's, so the steps the page
  // holds match them, and the person's button is held back; sent from the page
  // as they are, the held steps would reach the wallet and fail on the chain.
  it("asks for its steps when its values are the person's and their button is held back, so the held steps never reach the wallet", async () => {
    const active = wallet()
    replaceActiveEthereumWallet(active.selected)
    const page = proposalGroup(() => ({reason: "blocked", cause: "values", note: "Not your Key"}))
    page.held(theirReview)

    const answer = await page.call(theirs)

    expect(answer).toMatchObject({ok: false, error: {code: "blocked", message: "Not your Key"}})
    expect(active.sent).toEqual([])
    expect(page.told()).toEqual([["prepare_for_agent", {form: theirs, step: "propose", address: signer}]])
  })

  // Costly failure: with no wallet open the press was heard as the person's,
  // with the agent's values, clearing what the person typed and saving the
  // agent's words as theirs.
  it("tells the server nothing as the person when no wallet is open", async () => {
    const page = proposalGroup(() => ({review: proposeReview, send: "propose"}))

    const answer = await page.call({kind: "decision", key: "7", text: "The agent's words"})

    expect(answer).toMatchObject({ok: false, error: {code: "wallet_unavailable"}})
    expect(page.told()).toEqual([["step_failed", {step: "propose", reason: "wallet_unavailable", agent: true}]])
  })

  it("sends from the steps the page holds when its values match them, and says each report is the agent's", async () => {
    const active = wallet()
    replaceActiveEthereumWallet(active.selected)
    const page = proposalGroup(() => ({review: proposeReview, send: "propose"}), false)
    page.held(theirReview)

    const answer = await page.call(theirs)

    expect(answer).toMatchObject({ok: true, transaction_hash: hash})
    expect(active.sent).toHaveLength(1)
    expect(page.told()).toEqual([
      ["step_pressed", {step: "propose", form: theirs, agent: true}],
      ["step_sent", {review_id: "review-person", step: "propose", transaction_hash: hash, agent: true}],
    ])
  })

  it("reports a decline in the wallet as the agent's", async () => {
    const active = wallet({answer: () => { throw Object.assign(new Error("User rejected"), {code: 4001}) }})
    replaceActiveEthereumWallet(active.selected)
    const page = proposalGroup(() => ({review: proposeReview, send: "propose"}))

    const answer = await page.call({kind: "decision", key: "7", text: "The agent's words"})

    expect(answer).toMatchObject({ok: false, error: {code: "wallet_declined"}})
    expect(page.told().at(-1)).toEqual(["step_failed", {step: "propose", reason: "wallet_declined", agent: true}])
  })

  // Costly failure: the person pressed nothing, yet reads that the page lost
  // its connection and is asked to press again.
  it("answers that the page lost its connection, shows the person nothing, and reports the press as the agent's", async () => {
    replaceActiveEthereumWallet(wallet().selected)
    const page = proposalGroup(() => unreached)

    const answer = await page.call({kind: "decision", key: "7", text: "The agent's words"})

    expect(answer).toMatchObject({ok: false, error: {code: "connection_lost"}})
    expect(page.lostLine.hidden).toBe(true)
    expect(report).toHaveBeenCalledWith({name: "press.unsent", where: "propose", outcome: "lost", agent: true})
  })

  // Costly failure: the line the person's own lost press showed goes away
  // before they have pressed again.
  it("leaves the lost line the person's own press showed", async () => {
    replaceActiveEthereumWallet(wallet().selected)
    const page = proposalGroup(() => ({reason: "blocked", cause: "values", note: "Not your Key"}))
    page.lostLine.hidden = false

    await page.call({kind: "decision", key: "9", text: "The agent's words"})

    expect(page.lostLine.hidden).toBe(false)
  })
})

// Invariant: the lost line speaks for the person's own presses: their press
// the page could not get to the server shows it, and their next press hides it.
describe("the person's press and the lost line", () => {
  beforeEach(() => {
    vi.stubGlobal("window", Object.assign(new EventTarget(), {localStorage: memoryStorage()}))
    vi.stubGlobal("document", {})
  })

  it("shows it when the press can't reach the server, and hides it at their next press", async () => {
    const active = wallet()
    replaceActiveEthereumWallet(active.selected)
    let reached = false
    const page = group(() => (reached ? {review, send: "buy"} : unreached))

    page.press()
    await vi.waitFor(() => expect(page.lostLine.hidden).toBe(false))
    expect(report).toHaveBeenCalledWith({name: "press.unsent", where: "buy", outcome: "lost"})

    reached = true
    page.press()
    expect(page.lostLine.hidden).toBe(true)
    await vi.waitFor(() => expect(active.sent).toHaveLength(1))
  })
})

// Invariant: with no wallet open no wallet is asked, so the person's press is
// not heard either: nothing typed is cleared and no words are saved for a
// press that sent nothing.
describe("a press with no wallet open", () => {
  beforeEach(() => {
    vi.stubGlobal("window", Object.assign(new EventTarget(), {localStorage: memoryStorage()}))
    vi.stubGlobal("document", {})
  })

  it("reports only that no wallet answered", async () => {
    const page = group(() => ({review, send: "buy"}))
    page.held(review)

    page.press()

    await vi.waitFor(() =>
      expect(page.pushed).toContainEqual(["step_failed", {step: "buy", reason: "wallet_unavailable"}]),
    )
    expect(page.pushed.map(([event]) => event)).toEqual(["onchain_active_wallet", "step_failed"])
  })
})
