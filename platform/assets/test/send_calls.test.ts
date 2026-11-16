import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

import {press, type Review} from "../js/hooks/onchain_steps"
import {
  forgetWalletDisconnected,
  replaceActiveEthereumWallet,
  type EthereumProvider,
} from "../js/wallet_actions/connected_wallet"
import {builderCodeSuffix, sendStep, type TransactionStep} from "../js/wallet_actions/send_step"

const signer = "0x1111111111111111111111111111111111111111"
const fleet = "0x3333333333333333333333333333333333333333"
const marker = "80218021802180218021802180218021"
// Keyfleet's code, bc_u09360jo, as the server ends every step's data with it.
const suffix = `0x62635f7530393336306a6f0b00${marker}` as const
const data = `0xa9059cbb${"00".repeat(64)}${suffix.slice(2)}` as const
const sentHash = `0x${"ab".repeat(32)}`
const includedHash = `0x${"cd".repeat(32)}`
const base = {chain_id: 8453}
// Every wallet here is already on Base, so its switch is never asked.
const switchChain = async () => undefined
const step: TransactionStep = {kind: "transaction", step: "buy", to: fleet, data, value: "0x0"}
const review: Review = {id: "review-1", component_id: "buy-key-order", signer, chain: base, steps: [step], inputs: {}}

const notFound = () => {
  throw Object.assign(new Error("The method wallet_getCapabilities does not exist / is not available."), {code: -32601})
}
const onBase = {"0x2105": {dataSuffix: {supported: true}}}

const receipt = (status: "0x1" | "0x0") => ({
  logs: [],
  status,
  blockHash: `0x${"ee".repeat(32)}`,
  blockNumber: "0x10",
  gasUsed: "0x5208",
  transactionHash: includedHash,
})
const callsStatus = (status: number, receipts: unknown[] = []) => ({
  version: "2.0.0",
  id: "0xbatch",
  chainId: "0x2105",
  atomic: true,
  status,
  receipts,
})

type Request = {method: string; params?: unknown}

// A stand-in wallet on Base holding the signer, recording every request in
// order. `capabilities`, `calls` and `status` answer (or throw for)
// wallet_getCapabilities, wallet_sendCalls and each wallet_getCallsStatus.
function wallet({
  capabilities = notFound as () => unknown,
  calls = (count: number) => ({id: `0xbatch${count}`}) as unknown,
  status = (_id: string) => callsStatus(200, [receipt("0x1")]) as unknown,
} = {}) {
  const requests: Request[] = []
  let statusRead = () => {}
  const statusReads = (count: number) => {
    const reads = () => requests.filter(request => request.method === "wallet_getCallsStatus").length
    return new Promise<void>(resolve => {
      statusRead = () => reads() >= count && resolve()
      statusRead()
    })
  }
  const provider: EthereumProvider = {
    async request({method, params}) {
      requests.push({method, params})
      switch (method) {
        case "eth_chainId":
          return "0x2105"
        case "eth_accounts":
          return [signer]
        case "wallet_getCapabilities":
          return capabilities()
        case "wallet_sendCalls":
          return calls(requests.filter(request => request.method === "wallet_sendCalls").length)
        case "wallet_getCallsStatus":
          queueMicrotask(statusRead)
          return status((params as [string])[0])
        case "eth_sendTransaction":
          return sentHash
        default:
          throw Object.assign(new Error(`The wallet does not answer ${method}.`), {code: 4200})
      }
    },
  }
  const sends = () => requests.filter(({method}) => method === "eth_sendTransaction" || method === "wallet_sendCalls")
  // The request made just before each send.
  const beforeSends = () =>
    requests.flatMap((request, index) => (sends().includes(request) ? [requests[index - 1].method] : []))
  return {provider, requests, sends, beforeSends, statusReads}
}

const send = (provider: EthereumProvider, sent: TransactionStep = step) =>
  sendStep(base, signer, sent, () => ({address: signer, provider, switchChain}), () => {})

function memoryStorage() {
  const values = new Map<string, string>()
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => void values.set(key, value),
    removeItem: (key: string) => void values.delete(key),
  }
}

function pushes() {
  const pushed: [string, unknown][] = []
  return {pushed, push: (event: string, payload: unknown) => void pushed.push([event, payload])}
}

beforeEach(() => {
  vi.stubGlobal("window", {localStorage: memoryStorage(), dispatchEvent: () => true})
  forgetWalletDisconnected()
  replaceActiveEthereumWallet(null)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("a wallet that appends the builder code itself gets the step as one call", () => {
  it("sends one wallet_sendCalls with the step unchanged and the code from its data, and answers the included hash", async () => {
    const active = wallet({capabilities: () => onBase})

    expect(await send(active.provider)).toBe(includedHash)

    expect(active.sends()).toEqual([{
      method: "wallet_sendCalls",
      params: [{
        version: "2.0.0",
        chainId: "0x2105",
        from: signer,
        atomicRequired: false,
        calls: [{to: fleet, data, value: "0x0"}],
        capabilities: {dataSuffix: {value: suffix, optional: true}},
      }],
    }])
    expect(active.requests.find(({method}) => method === "wallet_getCapabilities")).toEqual({
      method: "wallet_getCapabilities",
      params: [signer, ["0x2105"]],
    })
    expect(active.requests.filter(({method}) => method === "wallet_getCallsStatus")).toEqual([
      {method: "wallet_getCallsStatus", params: ["0xbatch1"]},
    ])
    expect(active.beforeSends()).toEqual(["eth_chainId"])
  })

  it("takes a code the wallet reports for every chain, under 0x0", async () => {
    const active = wallet({capabilities: () => ({"0x0": {dataSuffix: {supported: true}}})})

    expect(await send(active.provider)).toBe(includedHash)
    expect(active.sends().map(({method}) => method)).toEqual(["wallet_sendCalls"])
  })

  it("answers the hash of a call that reverted once included, for the server to judge", async () => {
    const active = wallet({capabilities: () => onBase, status: () => callsStatus(500, [receipt("0x0")])})

    expect(await send(active.provider)).toBe(includedHash)
  })

  it("reports a press of it as sent with the included hash", async () => {
    const active = wallet({capabilities: () => onBase})
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain})
    const {pushed, push} = pushes()

    expect(await press(review, "buy", push)).toEqual({transaction_hash: includedHash})
    expect(pushed).toEqual([["step_sent", {review_id: "review-1", step: "buy", transaction_hash: includedHash}]])
  })
})

describe("every other wallet gets the step as a transaction, as before", () => {
  const today = [{from: signer, to: fleet, data, value: "0x0", chainId: "0x2105"}]

  it.each([
    ["does not know wallet_getCapabilities", notFound],
    ["refuses it for this account", () => {
      throw Object.assign(new Error("Unauthorized"), {code: 4100})
    }],
    ["answers nothing for the chain", () => ({})],
    ["answers without the capability", () => ({"0x2105": {atomic: {status: "supported"}}})],
    ["says it does not append one", () => ({"0x2105": {dataSuffix: {supported: false}}})],
    ["reports it for another chain only", () => ({"0x1": {dataSuffix: {supported: true}}})],
  ])("a wallet that %s gets one eth_sendTransaction", async (_case, capabilities) => {
    const active = wallet({capabilities})

    expect(await send(active.provider)).toBe(sentHash)
    expect(active.sends()).toEqual([{method: "eth_sendTransaction", params: today}])
    expect(active.beforeSends()).toEqual(["eth_chainId"])
  })

  it("does not ask a wallet what it can do for data with no code in it", async () => {
    const active = wallet({capabilities: () => onBase})
    const plain = {...step, data: "0xa9059cbb" as const}

    expect(await send(active.provider, plain)).toBe(sentHash)
    expect(active.requests.map(({method}) => method)).not.toContain("wallet_getCapabilities")
    expect(active.sends()).toEqual([{method: "eth_sendTransaction", params: [{...today[0], data: "0xa9059cbb"}]}])
  })
})

describe("a press through wallet_sendCalls reports only what the wallet said", () => {
  it("maps a decline to wallet_declined and sends nothing more", async () => {
    const active = wallet({
      capabilities: () => onBase,
      calls: () => {
        throw Object.assign(new Error("User rejected the request."), {code: 4001})
      },
    })
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain})
    const {pushed, push} = pushes()

    expect(await press(review, "buy", push)).toEqual({reason: "wallet_declined"})
    expect(active.sends().map(({method}) => method)).toEqual(["wallet_sendCalls"])
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "wallet_declined"}]])
  })

  it("maps a status that never arrives to send_unconfirmed, without a second send", async () => {
    vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout"]})
    const active = wallet({capabilities: () => onBase, status: () => callsStatus(100)})
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain})
    const {pushed, push} = pushes()

    const pressed = press(review, "buy", push)
    await active.statusReads(1)
    await vi.advanceTimersByTimeAsync(60_000)

    expect(await pressed).toEqual({reason: "send_unconfirmed"})
    expect(active.sends().map(({method}) => method)).toEqual(["wallet_sendCalls"])
    expect(pushed).toEqual([["step_failed", {step: "buy", reason: "send_unconfirmed"}]])
  })

  it("maps calls the wallet gave up on, with no transaction, to send_unconfirmed", async () => {
    const active = wallet({capabilities: () => onBase, status: () => callsStatus(400)})
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain})
    const {push} = pushes()

    expect(await press(review, "buy", push)).toEqual({reason: "send_unconfirmed"})
    expect(active.sends().map(({method}) => method)).toEqual(["wallet_sendCalls"])
  })

  it("sends a second press while the first is still waiting for its status", async () => {
    vi.useFakeTimers({toFake: ["setTimeout", "clearTimeout"]})
    let included = false
    const active = wallet({
      capabilities: () => onBase,
      status: () => (included ? callsStatus(200, [receipt("0x1")]) : callsStatus(100)),
    })
    replaceActiveEthereumWallet({address: signer, provider: active.provider, switchChain})
    const {pushed, push} = pushes()

    const first = press(review, "buy", push)
    await active.statusReads(1)
    const second = press(review, "buy", push)
    await active.statusReads(2)
    included = true
    await vi.advanceTimersByTimeAsync(1_000)

    expect(await Promise.all([first, second])).toEqual([{transaction_hash: includedHash}, {transaction_hash: includedHash}])
    expect(active.sends().map(({params}) => (params as [{calls: unknown}])[0].calls)).toEqual([
      [{to: fleet, data, value: "0x0"}],
      [{to: fleet, data, value: "0x0"}],
    ])
    expect(pushed.map(([event]) => event)).toEqual(["step_sent", "step_sent"])
  })
})

// A small deterministic generator, so sampled inputs repeat run to run.
function random(seed: number) {
  let state = seed
  return () => {
    state = (Math.imul(state, 1_103_515_245) + 12_345) >>> 0
    return state / 2 ** 32
  }
}

describe("the builder-code suffix is read from the end of the data", () => {
  const next = random(8021)
  const byte = (value: number) => value.toString(16).padStart(2, "0")
  const bytes = (count: number, pick = () => Math.floor(next() * 256)) =>
    Array.from({length: count}, () => byte(pick())).join("")
  const ascii = () => 0x20 + Math.floor(next() * 0x5f)
  const calldata = () => bytes(Math.floor(next() * 100))

  it("gives back a whole suffix of every code length, after any calldata", () => {
    for (let length = 0; length <= 255; length++) {
      const whole = `${bytes(length, ascii)}${byte(length)}00${marker}`
      const prefix = calldata()
      expect(builderCodeSuffix(`0x${prefix}${whole}`)).toBe(`0x${whole}`)
    }
    expect(builderCodeSuffix(data)).toBe(suffix)
  })

  it("gives nothing for a tail with another marker, another schema, or a length longer than the data", () => {
    for (let sample = 0; sample < 300; sample++) {
      const length = Math.floor(next() * 256)
      const codes = bytes(length, ascii)
      const prefix = calldata()

      const at = Math.floor(next() * marker.length)
      const digit = marker[at] === "0" ? "1" : "0"
      const otherMarker = `${marker.slice(0, at)}${digit}${marker.slice(at + 1)}`
      expect(builderCodeSuffix(`0x${prefix}${codes}${byte(length)}00${otherMarker}`)).toBeNull()

      const schema = 1 + Math.floor(next() * 255)
      expect(builderCodeSuffix(`0x${prefix}${codes}${byte(length)}${byte(schema)}${marker}`)).toBeNull()

      const room = prefix.length / 2 + length
      if (room < 255) {
        const longer = room + 1 + Math.floor(next() * (255 - room))
        expect(builderCodeSuffix(`0x${prefix}${codes}${byte(longer)}00${marker}`)).toBeNull()
      }
    }
  })

  it("gives nothing for data that is not whole bytes of hex, or too short for a length", () => {
    expect(builderCodeSuffix(`0x${"ab".repeat(4)}0${"00"}${marker}`)).toBeNull()
    expect(builderCodeSuffix(`0xzz0100${marker}`)).toBeNull()
    expect(builderCodeSuffix(`00${marker}`)).toBeNull()
    expect(builderCodeSuffix(`0x00${marker}`)).toBeNull()
    expect(builderCodeSuffix("0x")).toBeNull()
  })
})
