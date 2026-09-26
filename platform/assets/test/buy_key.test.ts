import {afterEach, describe as group, expect, it, vi} from "vitest"
import {
  decodeFunctionData,
  encodeAbiParameters,
  encodeErrorResult,
  encodeEventTopics,
  maxUint256,
  parseAbi,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem"

import {buyKeyHook} from "../js/hooks/buy_key"
import {
  buyKey,
  describe,
  failureOf,
  keyfleetAbi,
  outOfDateWords,
  purchasedKey,
  readKeyOrder,
  usdcAbi,
  type BuyUpdate,
  type KeyOrder,
} from "../js/wallet_actions/buy_key"
import type {EthereumProvider, SelectedWallet} from "../js/wallet_actions/connected_wallet"

const buyer = "0x1111111111111111111111111111111111111111" as Address
const signedIn = `0x${"9".repeat(40)}`
const fleet = "0x7777777777777777777777777777777777777777" as Address
const usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address
const referrer = "0x2222222222222222222222222222222222222222" as Address
const price = 42_998_170n
const now = 1_790_000_000_000
// Base's clock, deliberately not the computer's: the deadline counts from it.
const blockTime = 1_790_000_321n
const deadline = blockTime + 600n

const order: KeyOrder = readKeyOrder({
  chainId: "8453",
  fleet: fleet.toLowerCase(),
  usdc: usdc.toLowerCase(),
  price: price.toString(),
  priceLabel: "42.99817 USDC",
  referrer: referrer.toLowerCase(),
  deadlineSeconds: "600",
})

// The order a page renders with no referral.
const page = () => ({
  chainId: "8453",
  fleet,
  usdc,
  price: price.toString(),
  priceLabel: "42.99817 USDC",
  deadlineSeconds: "600",
})

const hash = (n: number) => toHex(n, {size: 32})
const revert = (data: Hex) => ({code: -32603, message: "Internal error", data: {code: 3, message: "execution reverted", data}})
const errorAbi = parseAbi(["error Error(string reason)"])

type Request = {method: string; params?: unknown[]}
type Chain = {
  chainId?: string
  allowance?: bigint
  // Networks the wallet already knows; switching to any other is error 4902.
  known?: string[]
  switchError?: unknown
  addError?: unknown
  switchTo?: string
  send?: (transaction: {to: string; data: Hex}, index: number) => Promise<unknown>
  receipt?: (hash: string) => unknown
  replay?: () => Promise<unknown>
}

function fakeWallet(chain: Chain = {}): SelectedWallet & {requests: Request[]} {
  const requests: Request[] = []
  let chainId = chain.chainId ?? "0x2105"
  const known = chain.known ?? ["0x1", "0x2105", "0x7a69"]
  let sends = 0
  const provider: EthereumProvider = {
    request: async (request: Request) => {
      requests.push(request)
      const [first, second] = request.params ?? []
      switch (request.method) {
        case "eth_chainId":
          return chainId
        case "wallet_switchEthereumChain": {
          if (chain.switchError) throw chain.switchError
          const target = (first as {chainId: string}).chainId
          if (!known.includes(target)) throw {code: 4902, message: "Unrecognized chain ID"}
          chainId = chain.switchTo ?? target
          return null
        }
        case "wallet_addEthereumChain":
          if (chain.addError) throw chain.addError
          known.push((first as {chainId: string}).chainId)
          return null
        case "eth_getBlockByNumber":
          return {number: "0x10", timestamp: toHex(blockTime)}
        case "eth_call":
          if (second === "latest") return toHex(chain.allowance ?? 0n, {size: 32})
          return (chain.replay ?? (async () => "0x"))()
        case "eth_sendTransaction":
          return (chain.send ?? (async () => hash(++sends)))(first as {to: string; data: Hex}, sends)
        case "eth_getTransactionReceipt":
          return chain.receipt ? chain.receipt(first as string) : purchaseReceipt(12n)
        default:
          throw new Error(`unexpected ${request.method}`)
      }
    },
  }
  return {address: buyer.toLowerCase(), provider, requests}
}

function purchaseReceipt(tokenId: bigint, status = "0x1") {
  return {
    status,
    blockNumber: "0x10",
    logs: [
      // The USDC transfer that paid for it comes first and is not the key.
      {
        address: usdc,
        topics: [
          "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hex,
          toHex(BigInt(buyer), {size: 32}),
          toHex(BigInt(fleet), {size: 32}),
        ],
        data: toHex(price, {size: 32}),
      },
      purchasedLog(fleet, tokenId),
    ],
  }
}

function purchasedLog(address: Address, tokenId: bigint) {
  return {
    address: address.toLowerCase(),
    // Every indexed argument is given, so every topic is filled.
    topics: encodeEventTopics({
      abi: keyfleetAbi,
      eventName: "Purchased",
      args: {tokenId, buyer, receiver: buyer},
    }) as Hex[],
    data: encodeAbiParameters(
      [
        {type: "address"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
        {type: "uint256"},
      ],
      [referrer, price, 1n, 2n, 3n, 4n, 5n],
    ),
  }
}

async function run(wallet: SelectedWallet, orderToBuy: KeyOrder = order): Promise<BuyUpdate[]> {
  const updates: BuyUpdate[] = []
  await buyKey(orderToBuy, wallet, update => updates.push(update), {
    now: () => now,
    wait: async () => undefined,
  })
  return updates
}

const sent = (wallet: {requests: Request[]}) =>
  wallet.requests
    .filter(request => request.method === "eth_sendTransaction")
    .map(request => request.params?.[0] as {from: string; to: string; data: Hex; value: string; chainId: string})

group("buying a key", () => {
  it("approves the price, then buys for the wallet with the shown price and a deadline ten minutes after Base's latest block", async () => {
    const wallet = fakeWallet({allowance: 0n})
    const updates = await run(wallet)

    expect(wallet.requests.map(request => request.method)).toEqual([
      "eth_chainId",
      "eth_call",
      "eth_sendTransaction",
      "eth_getTransactionReceipt",
      "eth_getBlockByNumber",
      "eth_sendTransaction",
      "eth_getTransactionReceipt",
    ])
    expect(wallet.requests.find(request => request.method === "eth_getBlockByNumber")?.params).toEqual(["latest", false])

    const [approval, purchase] = sent(wallet)
    expect(approval).toMatchObject({from: buyer, to: usdc, value: "0x0", chainId: "0x2105"})
    expect(purchase).toMatchObject({from: buyer, to: fleet, value: "0x0", chainId: "0x2105"})
    expect(decodeFunctionData({abi: keyfleetAbi, data: purchase.data})).toEqual({
      functionName: "purchase",
      args: [buyer, referrer, price, deadline],
    })

    expect(updates).toEqual([
      {kind: "wallet", step: "approve"},
      {kind: "sent", step: "approve", hash: hash(1)},
      {kind: "wallet", step: "purchase"},
      {kind: "sent", step: "purchase", hash: hash(2)},
      {kind: "bought", tokenId: 12n, hash: hash(2)},
    ])
    expect(describe(updates[0], order)).toBe("Approve spending 42.99817 USDC in your wallet.")
    expect(describe(updates[4], order)).toMatch(/^Confirmed\. Key 12 is yours\./)
  })

  it("approves exactly the price, never an unlimited amount", async () => {
    const wallet = fakeWallet({allowance: price - 1n})
    await run(wallet)

    const [approval] = sent(wallet)
    const {functionName, args} = decodeFunctionData({abi: usdcAbi, data: approval.data})
    expect(functionName).toBe("approve")
    expect(args).toEqual([fleet, price])
    expect(args?.[1]).not.toBe(maxUint256)
  })

  it("reads the allowance the wallet has given this fleet", async () => {
    const wallet = fakeWallet()
    await run(wallet)

    const read = wallet.requests.find(request => request.method === "eth_call")
    expect(read?.params?.[0]).toMatchObject({to: usdc})
    const {data} = read?.params?.[0] as {data: Hex}
    expect(decodeFunctionData({abi: usdcAbi, data})).toEqual({functionName: "allowance", args: [buyer, fleet]})
  })

  it("skips the approval when the allowance already covers the price", async () => {
    const wallet = fakeWallet({allowance: price})
    const updates = await run(wallet)

    expect(sent(wallet).map(transaction => transaction.to)).toEqual([fleet])
    expect(updates.map(update => update.kind)).toEqual(["wallet", "sent", "bought"])
  })

  it("sends no referrer as the zero address", async () => {
    const wallet = fakeWallet({allowance: price})
    await run(wallet, readKeyOrder(page()))

    const {args} = decodeFunctionData({abi: keyfleetAbi, data: sent(wallet)[0].data})
    expect(args?.[1]).toBe(zeroAddress)
  })

  it("asks the wallet to move to the fleet's network first", async () => {
    const wallet = fakeWallet({chainId: "0x1", allowance: price})
    await run(wallet)

    expect(wallet.requests[1]).toEqual({method: "wallet_switchEthereumChain", params: [{chainId: "0x2105"}]})
    expect(sent(wallet)).toHaveLength(1)
  })

  it("asks a wallet that has never been on Base to add it, then moves there", async () => {
    const wallet = fakeWallet({chainId: "0x1", known: ["0x1"], allowance: price})
    const updates = await run(wallet)

    expect(wallet.requests.slice(1, 4)).toEqual([
      {method: "wallet_switchEthereumChain", params: [{chainId: "0x2105"}]},
      {
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: "0x2105",
            chainName: "Base",
            nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
            rpcUrls: ["https://mainnet.base.org"],
            blockExplorerUrls: ["https://basescan.org"],
          },
        ],
      },
      {method: "wallet_switchEthereumChain", params: [{chainId: "0x2105"}]},
    ])
    expect(updates.at(-1)).toMatchObject({kind: "bought"})
  })

  it("buys a key priced beyond what a JavaScript number holds exactly", async () => {
    // Late Accelerant keys cost more than 2^53 atomic USDC.
    const huge = 2n ** 53n + 1n
    const wallet = fakeWallet({allowance: 0n})
    await run(wallet, readKeyOrder({...page(), price: huge.toString()}))

    const [approval, purchase] = sent(wallet)
    expect(decodeFunctionData({abi: usdcAbi, data: approval.data}).args).toEqual([fleet, huge])
    expect(decodeFunctionData({abi: keyfleetAbi, data: purchase.data}).args?.[2]).toBe(huge)
  })

  it("sends a second purchase when Buy is pressed again while the first is still in the wallet", async () => {
    let first = true
    const wallet = fakeWallet({
      allowance: price,
      send: () => {
        if (first) {
          first = false
          return new Promise(() => undefined)
        }
        return Promise.resolve(hash(9))
      },
    })

    const pending: BuyUpdate[] = []
    void buyKey(order, wallet, update => pending.push(update), {now: () => now, wait: async () => undefined})
    await vi.waitFor(() => expect(sent(wallet)).toHaveLength(1))

    const second = await run(wallet)

    expect(sent(wallet)).toHaveLength(2)
    expect(pending).toEqual([{kind: "wallet", step: "purchase"}])
    expect(second.at(-1)).toEqual({kind: "bought", tokenId: 12n, hash: hash(9)})
  })
})

group("reading the receipt", () => {
  it("takes the key number from this fleet's Purchased event", () => {
    expect(purchasedKey(purchaseReceipt(46_365n), fleet)).toBe(46_365n)
  })

  it("ignores a Purchased event from another contract", () => {
    const other = "0x9999999999999999999999999999999999999999" as Address
    const receipt = {logs: [purchasedLog(other, 3n), purchasedLog(fleet, 4n)]}
    expect(purchasedKey(receipt, fleet)).toBe(4n)
  })

  it("asks again when a receipt read fails, and confirms once it succeeds", async () => {
    let reads = 0
    const wallet = fakeWallet({
      allowance: price,
      receipt: () => {
        if (++reads === 1) throw new Error("network blip")
        return purchaseReceipt(7n)
      },
    })
    const updates = await run(wallet)

    expect(reads).toBe(2)
    expect(updates.at(-1)).toMatchObject({kind: "bought", tokenId: 7n})
  })

  it("waits for the first block that includes the purchase", async () => {
    let reads = 0
    const wallet = fakeWallet({
      allowance: price,
      receipt: () => (++reads < 3 ? null : purchaseReceipt(7n)),
    })
    const updates = await run(wallet)

    expect(reads).toBe(3)
    expect(updates.at(-1)).toMatchObject({kind: "bought", tokenId: 7n})
  })
})

group("saying what went wrong", () => {
  const cases: [string, unknown, string][] = [
    [
      "the price moved",
      revert(encodeErrorResult({abi: keyfleetAbi, errorName: "PriceAboveMax", args: [price * 2n, price]})),
      "The price went up before this purchase went through, so no key was bought and no USDC was taken. Reload the page for the latest price, then press Buy again.",
    ],
    [
      "the deadline passed",
      revert(encodeErrorResult({abi: keyfleetAbi, errorName: "Expired", args: [deadline]})),
      "The purchase took more than 10 minutes to reach Base, so it expired. Press Buy again.",
    ],
    [
      "the holding limit",
      revert(encodeErrorResult({abi: keyfleetAbi, errorName: "HoldingLimitExceeded", args: [buyer, 8n, 5n]})),
      "Your wallet already holds as many level 8 keys as one wallet may (5).",
    ],
    [
      "the fleet sold out",
      {code: 3, message: "execution reverted", data: encodeErrorResult({abi: keyfleetAbi, errorName: "SoldOut"})},
      "Every key in this fleet has now been sold.",
    ],
    [
      "not enough USDC",
      revert(encodeErrorResult({abi: errorAbi, errorName: "Error", args: ["ERC20: transfer amount exceeds balance"]})),
      "Your wallet doesn’t have enough USDC. This key costs 42.99817 USDC.",
    ],
    [
      "an approval another purchase used",
      {cause: {cause: revert(encodeErrorResult({abi: errorAbi, errorName: "Error", args: ["ERC20: transfer amount exceeds allowance"]}))}},
      "The purchase couldn’t use your USDC approval, so no key was bought. Press Buy again; your wallet asks for a new approval if one is needed.",
    ],
    [
      "a rejection in the wallet",
      {code: 4001, message: "User rejected the request."},
      "You declined in your wallet, so no key was bought.",
    ],
    [
      "a rejection wrapped by the wallet library",
      {name: "TransactionExecutionError", cause: {code: 4001}},
      "You declined in your wallet, so no key was bought.",
    ],
    [
      "anything else",
      {code: -32000, message: "nonce too low", data: "0xdeadbeef00"},
      "The purchase didn’t go through. Try again.",
    ],
  ]

  it.each(cases)("%s", (_name, error, words) => {
    expect(describe({kind: "failed", ...failureOf(error)}, order)).toBe(words)
  })

  it("gives the time limit the page set", () => {
    const shorter = readKeyOrder({...page(), deadlineSeconds: "300"})
    expect(describe({kind: "failed", reason: "expired"}, shorter)).toBe(
      "The purchase took more than 5 minutes to reach Base, so it expired. Press Buy again.",
    )
  })

  it("asks the buyer to switch to Base when they decline the switch", async () => {
    const wallet = fakeWallet({chainId: "0x1", switchError: {code: 4001, message: "User rejected the request."}})
    const updates = await run(wallet)

    expect(sent(wallet)).toHaveLength(0)
    expect(updates).toEqual([{kind: "failed", reason: "wrong_network"}])
    expect(describe(updates[0], order)).toBe("Your wallet is on another network. Switch it to Base and press Buy again.")
  })

  it("asks the buyer to switch to Base when they decline adding it", async () => {
    const wallet = fakeWallet({chainId: "0x1", known: ["0x1"], addError: {code: 4001}})
    const updates = await run(wallet)

    expect(wallet.requests.map(request => request.method)).toContain("wallet_addEthereumChain")
    expect(sent(wallet)).toHaveLength(0)
    expect(updates).toEqual([{kind: "failed", reason: "wrong_network"}])
  })

  it("offers to add no network but Base", async () => {
    const wallet = fakeWallet({chainId: "0x1", known: ["0x1"]})
    const updates = await run(wallet, readKeyOrder({...page(), chainId: "31337"}))

    expect(wallet.requests.map(request => request.method)).not.toContain("wallet_addEthereumChain")
    expect(updates).toEqual([{kind: "failed", reason: "wrong_network"}])
  })

  it("names a wallet that stays on another network after agreeing to switch", async () => {
    const updates = await run(fakeWallet({chainId: "0x1", switchTo: "0x1"}))
    expect(updates).toEqual([{kind: "failed", reason: "wrong_network"}])
  })

  it("explains a purchase that reverted in its block by asking that block why", async () => {
    const wallet = fakeWallet({
      allowance: price,
      receipt: () => purchaseReceipt(0n, "0x0"),
      replay: async () => {
        throw revert(encodeErrorResult({abi: keyfleetAbi, errorName: "PriceAboveMax", args: [price * 2n, price]}))
      },
    })
    const updates = await run(wallet)

    const replay = wallet.requests.at(-1)
    expect(replay?.method).toBe("eth_call")
    expect(replay?.params?.[1]).toBe("0x10")
    expect(updates.at(-1)).toEqual({kind: "failed", reason: "price_moved"})
  })

  it("says so when the wallet rejects the approval, and sends no purchase", async () => {
    const wallet = fakeWallet({
      send: async () => {
        throw {code: 4001}
      },
    })
    const updates = await run(wallet)

    expect(sent(wallet)).toHaveLength(1)
    expect(updates.at(-1)).toEqual({kind: "failed", reason: "rejected"})
  })

  it("stops at an approval that reverted", async () => {
    const wallet = fakeWallet({receipt: () => ({status: "0x0", blockNumber: "0x10", logs: []})})
    const updates = await run(wallet)

    expect(sent(wallet)).toHaveLength(1)
    expect(updates.at(-1)).toEqual({kind: "failed", reason: "approval_failed"})
  })

  it("calls a purchase still unseen when the time runs out unconfirmed, not failed", async () => {
    let clock = now
    let reads = 0
    const wallet = fakeWallet({
      allowance: price,
      receipt: () => {
        reads += 1
        return null
      },
    })
    const updates: BuyUpdate[] = []
    await buyKey(order, wallet, update => updates.push(update), {
      now: () => clock,
      wait: async milliseconds => {
        clock += milliseconds
      },
      pollMs: 1_000,
      receiptTimeoutMs: 5_000,
    })

    expect(reads).toBe(6)
    expect(updates.at(-1)).toEqual({kind: "failed", reason: "unconfirmed"})
    expect(describe(updates.at(-1)!, order)).toBe(
      "Base hasn’t confirmed this yet. Check your wallet’s activity before trying again.",
    )
  })
})

group("the page's order", () => {
  it("reads the price as exact atomic USDC", () => {
    expect(order).toEqual({
      chainId: 8453,
      fleet,
      usdc,
      price,
      priceLabel: "42.99817 USDC",
      referrer,
      deadlineSeconds: 600n,
    })
  })

  it.each([["price", "42.99"], ["price", "0"], ["fleet", "0x123"], ["chainId", ""], ["referrer", "0xnope"]])(
    "calls a page with a malformed %s out of date",
    (field, value) => {
      expect(() => readKeyOrder({...page(), [field]: value})).toThrow()
    },
  )
})

// Vitest here runs without a document, so the hook gets the small surface it
// touches: the order's data, a click listener, the status list, the wallet
// note and the window's wallet events.
function mountHook(
  wallet: SelectedWallet | null,
  dataset: Record<string, string> = page(),
  signedIn: string[] = [buyer.toLowerCase()],
) {
  let listener: ((event: Event) => void) | undefined
  let connected = wallet
  const walletListeners = new Set<() => void>()
  const dispatchEvent = vi.fn()
  // The reader asked for less motion, so a refusal's shake never runs here.
  vi.stubGlobal("matchMedia", () => ({matches: true}))
  vi.stubGlobal("window", {
    addEventListener: (_name: string, handler: () => void) => walletListeners.add(handler),
    removeEventListener: (_name: string, handler: () => void) => walletListeners.delete(handler),
    dispatchEvent,
  })
  let noteText = ""
  const note = {
    get textContent() {
      return noteText
    },
    set textContent(text: string | null) {
      noteText = text ?? ""
    },
  }
  const entries: {textContent: string; dataset: Record<string, string>; remove(): void}[] = []
  const list = {
    prepend: (entry: (typeof entries)[number]) => entries.unshift(entry),
    get children() {
      return entries
    },
    get lastElementChild() {
      return entries.at(-1) ?? null
    },
  }
  const button = {
    disabled: false,
    closest: (selector: string) => (selector === "[data-buy-key]" ? button : null),
    setAttribute: vi.fn(),
    toggleAttribute: vi.fn(),
  }
  const el = {
    dataset: {signedIn: JSON.stringify(signedIn), ...dataset},
    addEventListener: (_name: string, handler: (event: Event) => void) => {
      listener = handler
    },
    removeEventListener: vi.fn(),
    querySelector: (selector: string) => ({"[data-wallet-note]": note, "#buy-key-status": list})[selector] ?? null,
    ownerDocument: {
      createElement: () => {
        const entry = {
          textContent: "",
          dataset: {} as Record<string, string>,
          remove: () => void entries.splice(entries.indexOf(entry), 1),
        }
        return entry
      },
    },
  }
  const purchases: KeyOrder[] = []
  const wallets: SelectedWallet[] = []
  const reports: ((update: BuyUpdate) => void)[] = []
  const hook = buyKeyHook(
    () => connected,
    async (bought, buyingWallet, report) => {
      purchases.push(bought)
      wallets.push(buyingWallet)
      reports.push(report)
      await new Promise(() => undefined)
    },
  )
  const context = {el}
  hook.mounted!.call(context)
  return {
    press: () => listener!({target: button} as unknown as Event),
    purchases,
    wallets,
    reports,
    entries,
    note,
    dispatchEvent,
    connect: (next: SelectedWallet | null) => {
      connected = next
      for (const changed of walletListeners) changed()
    },
    watching: () => walletListeners.size,
    destroy: () => hook.destroyed!.call(context),
    button,
  }
}

group("the Buy button", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("starts a purchase on every press, however many are still pending", () => {
    const hook = mountHook(fakeWallet())

    hook.press()
    hook.press()
    hook.press()

    expect(hook.purchases).toHaveLength(3)
    expect(hook.entries).toHaveLength(3)
    expect(hook.button.disabled).toBe(false)
    expect(hook.button.setAttribute).not.toHaveBeenCalled()
    expect(hook.button.toggleAttribute).not.toHaveBeenCalled()
  })

  it("asks for a wallet when none is connected", () => {
    const hook = mountHook(null)

    hook.press()

    expect(hook.purchases).toHaveLength(0)
    expect(hook.dispatchEvent.mock.calls[0][0].type).toBe("ash:wallet-connect")
    expect(hook.entries[0].textContent).toBe("Connect a wallet, then press Buy again.")
  })

  it("asks for a refresh when the page's order can't be read, and buys nothing", () => {
    const hook = mountHook(fakeWallet(), {...page(), price: "12.5"})
    hook.press()

    expect(hook.purchases).toHaveLength(0)
    expect(hook.entries[0].textContent).toBe(outOfDateWords)
    expect(hook.entries[0].dataset.tone).toBe("error")
  })

  it("shows each press's progress, through to the key bought", () => {
    const hook = mountHook(fakeWallet())
    hook.press()

    hook.reports[0]({kind: "wallet", step: "purchase"})
    expect(hook.entries[0].textContent).toBe("Confirm the purchase in your wallet.")

    hook.reports[0]({kind: "bought", tokenId: 41n, hash: hash(1)})
    expect(hook.entries[0].textContent).toBe(
      "Confirmed. Key 41 is yours. It shows as yours on the map in a few seconds.",
    )

    hook.reports[0]({kind: "failed", reason: "rejected"})
    expect(hook.entries[0].dataset.tone).toBe("error")
  })

  it("keeps the latest five presses on show", () => {
    const hook = mountHook(fakeWallet())
    for (let press = 0; press < 7; press++) hook.press()

    expect(hook.purchases).toHaveLength(7)
    expect(hook.entries).toHaveLength(5)
  })

  it("stops watching the connected wallet once it has left", () => {
    const hook = mountHook(fakeWallet())
    expect(hook.watching()).toBe(1)
    hook.destroy()
    expect(hook.watching()).toBe(0)
  })

  it("names both wallets when the connected one isn't the signed-in one, and still buys with the connected one", () => {
    const connected = fakeWallet()
    const hook = mountHook(connected, page(), [signedIn])

    expect(hook.note.textContent).toBe(
      "You’re signed in as 0x9999…9999 but your wallet is on 0x1111…1111. Presses here go to 0x1111…1111.",
    )

    hook.press()
    hook.press()
    expect(hook.wallets).toEqual([connected, connected])
    expect(hook.button.disabled).toBe(false)
    expect(hook.button.setAttribute).not.toHaveBeenCalled()
  })

  it("updates the note as the connected wallet changes", () => {
    const hook = mountHook(null, page(), [signedIn])
    expect(hook.note.textContent).toBe("")

    hook.connect(fakeWallet())
    expect(hook.note.textContent).toMatch(/^You’re signed in as 0x9999…9999/)

    hook.connect({...fakeWallet(), address: signedIn})
    expect(hook.note.textContent).toBe("")
  })

  it("says nothing about wallets to someone signed out", () => {
    const hook = mountHook(fakeWallet(), page(), [])
    expect(hook.note.textContent).toBe("")
  })
})
