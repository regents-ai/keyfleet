import {afterEach, describe as group, expect, it, vi} from "vitest"
import {
  decodeFunctionData,
  encodeErrorResult,
  getAddress,
  maxUint256,
  parseAbi,
  toHex,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from "viem"

import {fleetActionHook} from "../js/hooks/fleet_action"
import type {EthereumProvider, SelectedWallet} from "../js/wallet_actions/connected_wallet"
import {
  describe,
  encode,
  fleetAbi,
  outOfDateWords,
  readAction,
  readTarget,
  refusalOf,
  runAction,
  Unreadable,
  votesAbi,
  type ActionUpdate,
  type Press,
  type Target,
} from "../js/wallet_actions/fleet_action"
import {unreadableSignedInWords} from "../js/wallet_actions/signed_in"

const voter = "0x1111111111111111111111111111111111111111" as Address
const votes = "0x9999999999999999999999999999999999999999" as Address
const fleet = "0x7777777777777777777777777777777777777777" as Address
const usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address
const weth = getAddress(`0x${"c".repeat(40)}`)
const unknownToken = `0x${"d".repeat(40)}` as Address
const recipient = "0x2222222222222222222222222222222222222222" as Address
const signedIn = `0x${"5".repeat(40)}`
const digest = `0x${"ab".repeat(32)}` as Hex
const target: Target = readTarget({chainId: "8453", to: votes})
const assets = JSON.stringify({
  [usdc.toLowerCase()]: {decimals: 6, unit: "USDC"},
  [weth.toLowerCase()]: {decimals: 18, unit: "WETH 0xcccc…cccc"},
  [unknownToken]: {decimals: 0, unit: "smallest units of token 0xdddd…dddd"},
})

const hash = (n: number) => toHex(n, {size: 32})
const revert = (data: Hex) => ({code: -32603, message: "Internal error", data: {code: 3, message: "execution reverted", data}})
const refusals = parseAbi([
  "error AlreadyVoted(uint256 tokenId)",
  "error KeyNotEligible(uint256 tokenId)",
  "error NotAuthorizedForKey(uint256 tokenId, address owner)",
  "error VotingClosed(uint64 closesAt)",
  "error ZeroAmount()",
  "error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found)",
  "error Error(string reason)",
])

// What each form holds when its button is pressed.
const forms: Record<string, Record<string, string>> = {
  vote: {keys: "3, 7 12"},
  propose_decision: {key: "4", text: "Adopt the new rules\nfrom today", digest: digest.slice(2)},
  propose_pay: {key: "4", asset: usdc.toLowerCase(), amount: "1,250.5", recipient, text: "Pay the designer", digest},
  propose_launch: {
    key: "4",
    name: "Cascade Research",
    symbol: "CSR",
    description: "Research the fleet funds",
    website: "https://example.test",
    image: "ipfs://cascade",
    raise: "250000.5",
    until: "2026-10-23T18:30",
    digest: "",
  },
  delegate: {delegate: recipient.toLowerCase()},
}

// The data a button and its group carry on the page.
const buttonData: Record<string, Record<string, string>> = {
  vote: {proposal: "5", support: "yes"},
  execute: {proposal: "5"},
  propose_pay: {assets},
}

function press(name: string, fields: Record<string, string> = forms[name] ?? {}): Press {
  return readAction(name, buttonData[name] ?? {}, field => fields[field] ?? "")
}

type Request = {method: string; params?: unknown[]}
type Chain = {
  chainId?: string
  switchError?: unknown
  send?: () => Promise<unknown>
  receipt?: () => unknown
  replay?: () => Promise<unknown>
}

function fakeWallet(chain: Chain = {}): SelectedWallet & {requests: Request[]} {
  const requests: Request[] = []
  let chainId = chain.chainId ?? "0x2105"
  let sends = 0
  const provider: EthereumProvider = {
    request: async (request: Request) => {
      requests.push(request)
      switch (request.method) {
        case "eth_chainId":
          return chainId
        case "wallet_switchEthereumChain":
          if (chain.switchError) throw chain.switchError
          chainId = (request.params![0] as {chainId: string}).chainId
          return null
        case "eth_sendTransaction":
          return (chain.send ?? (async () => hash(++sends)))()
        case "eth_getTransactionReceipt":
          return chain.receipt ? chain.receipt() : {status: "0x1", blockNumber: "0x10", logs: []}
        case "eth_call":
          return (chain.replay ?? (async () => "0x"))()
        default:
          throw new Error(`unexpected ${request.method}`)
      }
    },
  }
  return {address: voter.toLowerCase(), provider, requests}
}

async function run(action: Press, wallet: SelectedWallet, to: Target = target) {
  const updates: ActionUpdate[] = []
  await runAction(to, action, wallet, update => updates.push(update), {wait: async () => undefined})
  return updates
}

const sent = (wallet: {requests: Request[]}) =>
  wallet.requests
    .filter(request => request.method === "eth_sendTransaction")
    .map(request => request.params![0] as {from: string; to: string; data: Hex; value: string; chainId: string})

group("what each button asks the contract", () => {
  it("votes with every key named, one vote each", () => {
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("vote"))})).toEqual({
      functionName: "vote",
      args: [5n, [3n, 7n, 12n], true],
    })
    const no = readAction("vote", {proposal: "5", support: "no"}, () => "9")
    expect(decodeFunctionData({abi: votesAbi, data: encode(no)}).args).toEqual([5n, [9n], false])
  })

  it("carries a proposal out by its number, whatever its kind", () => {
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("execute"))})).toEqual({
      functionName: "execute",
      args: [5n],
    })
  })

  it("proposes a decision with its text as written", () => {
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("propose_decision"))})).toEqual({
      functionName: "proposeDecision",
      args: [4n, "Adopt the new rules\nfrom today", digest],
    })
  })

  it("proposes a payment in the token's smallest units, exactly", () => {
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("propose_pay"))})).toEqual({
      functionName: "proposePay",
      args: [4n, usdc, 1_250_500_000n, recipient, "Pay the designer", digest],
    })

    const inWeth = press("propose_pay", {...forms.propose_pay, asset: weth, amount: "0.000000000000001234"})
    expect(decodeFunctionData({abi: votesAbi, data: encode(inWeth)}).args.slice(1, 3)).toEqual([weth, 1_234n])
  })

  it.each([
    ["1,234.5", 1_234_500_000n, "1,234.5 USDC"],
    ["1234.5", 1_234_500_000n, "1,234.5 USDC"],
    ["250.000", 250_000_000n, "250 USDC"],
    ["1.0000000", 1_000_000n, "1 USDC"],
    ["12,345,678", 12_345_678_000_000n, "12,345,678 USDC"],
  ])("reads %s with commas only between thousands and a point for decimals", (written, units, words) => {
    expect(press("propose_pay", {...forms.propose_pay, amount: written})).toMatchObject({amount: units, amountWords: words})
  })

  it.each(["12,5", "1,2,3", "1,23", "12,50.5"])("refuses %s, which reads as a decimal comma", written => {
    expect(() => press("propose_pay", {...forms.propose_pay, amount: written})).toThrow(
      "Use a point for decimals, like 12.5. Commas can only group thousands, like 1,250.",
    )
  })

  it("pays a token whose decimals aren't known in its smallest units", () => {
    const paid = press("propose_pay", {...forms.propose_pay, asset: unknownToken, amount: "125"})
    expect(paid).toMatchObject({amount: 125n, amountWords: "125 smallest units of token 0xdddd…dddd"})
    expect(() => press("propose_pay", {...forms.propose_pay, asset: unknownToken, amount: "12.5"})).toThrow(
      "This token is counted in whole units only.",
    )
  })

  it("takes an address in one case, or mixed case only when its checksum holds", () => {
    const mixed = getAddress(`0x${"ab".repeat(20)}`)
    const miscased = `${mixed.slice(0, -1)}${mixed.at(-1) === "b" ? "B" : "b"}`
    expect(press("propose_pay", {...forms.propose_pay, recipient: mixed})).toMatchObject({recipient: mixed})
    expect(press("propose_pay", {...forms.propose_pay, recipient: mixed.toLowerCase()})).toMatchObject({recipient: mixed})
    expect(press("propose_pay", {...forms.propose_pay, recipient: `0x${mixed.slice(2).toUpperCase()}`})).toMatchObject({
      recipient: mixed,
    })
    expect(() => press("propose_pay", {...forms.propose_pay, recipient: `0X${mixed.slice(2).toLowerCase()}`})).toThrow(
      "The wallet to pay isn’t a valid address.",
    )
    expect(() => press("propose_pay", {...forms.propose_pay, recipient: miscased})).toThrow(
      "The wallet to pay isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers.",
    )
  })

  it("sends a last day that has passed since 1970, for the contract to refuse", () => {
    expect(press("propose_launch", {...forms.propose_launch, until: "1999-06-01T00:00"})).toMatchObject({
      envelope: {executionExpiry: BigInt(Date.UTC(1999, 5, 1) / 1000)},
    })
    expect(press("propose_launch", {...forms.propose_launch, until: "1970-01-01T00:00"})).toMatchObject({
      envelope: {executionExpiry: 0n},
    })
  })

  it("reads a launch's last day to the second when seconds are given", () => {
    const launch = press("propose_launch", {...forms.propose_launch, until: "2028-02-29T23:59:59"})
    expect(launch).toMatchObject({envelope: {executionExpiry: BigInt(Date.UTC(2028, 1, 29, 23, 59, 59) / 1000)}})
  })

  it("calls a vote whose side the page doesn't say out of date, not the voter's mistake", () => {
    let thrown: unknown
    try {
      readAction("vote", {proposal: "5", support: "maybe"}, () => "3")
    } catch (error) {
      thrown = error
    }
    expect(thrown).toBeInstanceOf(Error)
    expect(thrown).not.toBeInstanceOf(Unreadable)
  })

  it("proposes a launch with its fields as written and its last second in UTC", () => {
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("propose_launch"))})).toEqual({
      functionName: "proposeAutolaunch",
      args: [
        4n,
        {
          name: "Cascade Research",
          symbol: "CSR",
          description: "Research the fleet funds",
          website: "https://example.test",
          image: "ipfs://cascade",
          requiredRegentRaised: 250_000_500_000_000_000_000_000n,
          narrativeDigest: zeroHash,
          executionExpiry: BigInt(Date.UTC(2026, 9, 23, 18, 30) / 1000),
        },
      ],
    })
  })

  it("lets another wallet vote, and stops it with the zero address", () => {
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("delegate"))})).toEqual({
      functionName: "setVotingDelegate",
      args: [recipient],
    })
    expect(decodeFunctionData({abi: votesAbi, data: encode(press("clear_delegate"))}).args).toEqual([zeroAddress])
  })

  it("sends the stakers their share", () => {
    expect(decodeFunctionData({abi: fleetAbi, data: encode(press("send_share"))}).functionName).toBe("sendProtocolShare")
  })

  // Anything the call can carry is sent, and the contract decides.
  it("sends what the contract will refuse rather than refusing it here", () => {
    expect(press("vote", {keys: ""})).toMatchObject({keys: []})
    expect(press("vote", {keys: "0, 03"})).toMatchObject({keys: [0n, 3n]})
    expect(press("propose_decision", {key: "0"})).toMatchObject({key: 0n})
    expect(press("vote", {keys: `${maxUint256}`})).toMatchObject({keys: [maxUint256]})
    expect(press("propose_decision", {key: "4"})).toMatchObject({text: "", digest: zeroHash})
    expect(press("propose_pay", {...forms.propose_pay, amount: "0"})).toMatchObject({amount: 0n})
    expect(press("propose_launch", {...forms.propose_launch, name: ""})).toMatchObject({envelope: {name: ""}})
  })

  it.each([
    ["vote", {keys: "3, x"}, "Key numbers are whole numbers, like 3, 7, 12."],
    ["propose_decision", {key: "four"}, "Name the key you’re proposing with, like 12."],
    ["propose_pay", {...forms.propose_pay, key: ""}, "Name the key you’re proposing with, like 12."],
    ["propose_pay", {...forms.propose_pay, amount: "1.2345678"}, "This token has at most 6 decimal places."],
    ["propose_pay", {...forms.propose_pay, amount: "twelve"}, "Write the amount as a number, like 12.5."],
    ["propose_pay", {...forms.propose_pay, recipient: "0x12"}, "The wallet to pay isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers."],
    ["propose_pay", {...forms.propose_pay, digest: "0x12"}, "A fingerprint is 64 letters and numbers, 0 to 9 and a to f. Leave it empty if there is none."],
    ["propose_launch", {...forms.propose_launch, until: ""}, "Choose the last day and time, in UTC, the launch can be carried out."],
    ["propose_launch", {...forms.propose_launch, raise: `${2n ** 128n}`}, "That amount is too large."],
    ["propose_launch", {...forms.propose_launch, until: "2026-02-30T18:30"}, "That day or time doesn’t exist. Choose the last day and time, in UTC, the launch can be carried out."],
    ["propose_launch", {...forms.propose_launch, until: "2026-10-23T24:30"}, "That day or time doesn’t exist. Choose the last day and time, in UTC, the launch can be carried out."],
    ["propose_launch", {...forms.propose_launch, until: "0026-10-23T18:30"}, "That date has already passed. The last day has to come after voting on the launch closes."],
    ["propose_launch", {...forms.propose_launch, until: "1969-12-31T23:59"}, "That date has already passed. The last day has to come after voting on the launch closes."],
    ["propose_launch", {...forms.propose_launch, until: "0026-02-29T18:30"}, "That day or time doesn’t exist. Choose the last day and time, in UTC, the launch can be carried out."],
    ["vote", {keys: `3, ${maxUint256 + 1n}`}, "That key number is larger than any key number can be."],
    ["propose_decision", {key: `${maxUint256 + 1n}`}, "That key number is larger than any key number can be."],
    ["delegate", {delegate: "someone"}, "The wallet to vote for you isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers."],
  ])("says plainly when %s can't be put into a call", (name, fields, words) => {
    expect(() => press(name, fields)).toThrow(words)
  })
})

group("sending a press", () => {
  it("moves the wallet to Base and sends to the contract the page named, then confirms on the first block", async () => {
    const wallet = fakeWallet({chainId: "0x1"})
    const updates = await run(press("vote"), wallet)

    expect(updates.map(update => update.kind)).toEqual(["switching", "wallet", "sent", "done"])
    expect(sent(wallet)).toEqual([{from: voter, to: votes, data: encode(press("vote")), value: "0x0", chainId: "0x2105"}])
    expect(describe(updates[0], press("vote"))).toBe("Switching your wallet to Base…")
    expect(describe(updates[1], press("vote"))).toBe("Voting yes on proposal 5 with keys 3, 7, 12. Confirm in your wallet.")
    expect(describe(updates[3], press("vote"))).toBe(
      "Confirmed. Keys 3, 7, 12 voted yes. The count here catches up in a few seconds.",
    )
  })

  it("goes straight to the wallet when it is already on Base", async () => {
    const updates = await run(press("execute"), fakeWallet())
    expect(updates.map(update => update.kind)).toEqual(["wallet", "sent", "done"])
  })

  it.each([
    ["propose_pay", forms.propose_pay, "Proposing 1,250.5 USDC to 0x2222…2222, with key 4. Confirm in your wallet."],
    [
      "propose_pay",
      {...forms.propose_pay, asset: unknownToken, amount: "125"},
      "Proposing 125 smallest units of token 0xdddd…dddd to 0x2222…2222, with key 4. Confirm in your wallet.",
    ],
    ["propose_launch", forms.propose_launch, "Proposing a launch that raises 250,000.5 REGENT, with key 4. Confirm in your wallet."],
    ["execute", {}, "Carrying out proposal 5. Confirm in your wallet."],
    ["clear_delegate", {}, "Stopping any other wallet voting for you. Confirm in your wallet."],
  ])("names what %s asks before the wallet does", (name, fields, words) => {
    expect(describe({kind: "wallet"}, press(name, fields))).toBe(words)
  })

  it("tells the proposer their proposal is on its way to the list", async () => {
    const updates = await run(press("propose_decision"), fakeWallet())
    expect(describe(updates.at(-1)!, press("propose_decision"))).toBe(
      "Confirmed. Your proposal joins the list in a few seconds, and voting on it is open.",
    )
  })

  it("sends the stakers' share to the fleet contract", async () => {
    const wallet = fakeWallet()
    const updates = await run(press("send_share"), wallet, readTarget({chainId: "8453", to: fleet}))
    expect(sent(wallet)[0].to).toBe(fleet)
    expect(describe(updates.at(-1)!, press("send_share"))).toMatch(/^Confirmed\. The stakers’ share has been sent\./)
  })

  it("sends every press, even while earlier ones are still in the wallet", async () => {
    const wallet = fakeWallet({send: () => new Promise(() => undefined)})
    for (let count = 0; count < 3; count++) void run(press("execute"), wallet)
    await vi.waitFor(() => expect(sent(wallet)).toHaveLength(3))
  })

  it("explains a press that failed in its block by asking that block why", async () => {
    const wallet = fakeWallet({
      receipt: () => ({status: "0x0", blockNumber: "0x10", logs: []}),
      replay: async () => {
        throw revert(encodeErrorResult({abi: refusals, errorName: "AlreadyVoted", args: [7n]}))
      },
    })
    const updates = await run(press("vote"), wallet)

    expect(wallet.requests.find(request => request.method === "eth_call")?.params?.[1]).toBe("0x10")
    expect(describe(updates.at(-1)!, press("vote"))).toBe(
      "Key 7 has already voted on this proposal, so none of these votes were counted.",
    )
  })

  it.each([
    ["vote", refusals, "VotingClosed", [1n], "Voting on this proposal has closed, so the vote wasn’t counted."],
    ["vote", refusals, "NotAuthorizedForKey", [4n, recipient], "Key 4 is held by 0x2222…2222, who hasn’t let this wallet vote for them."],
    ["propose_decision", refusals, "KeyNotEligible", [9n], "Key 9 hasn’t been sold yet."],
    ["send_share", refusals, "ZeroAmount", [], "Nothing is set aside for REGENT stakers right now, so there was nothing to send."],
    ["propose_pay", refusals, "ZeroAmount", [], "The amount has to be more than zero."],
    ["propose_launch", refusals, "MetadataFieldTooLong", [1n, 16n, 20n], "The launch’s symbol is too long: it can be at most 16 bytes, and this is 20. Plain letters and numbers take one byte each; accented letters take two, and emoji take four."],
  ] as const)("words the contract's refusal of %s plainly", (name, abi, errorName, args, words) => {
    const data = encodeErrorResult({abi, errorName, args} as Parameters<typeof encodeErrorResult>[0])
    expect(describe({kind: "failed", ...refusalOf(revert(data))}, press(name))).toBe(words)
  })

  it("calls a refusal it doesn't know unknown", () => {
    const data = encodeErrorResult({abi: refusals, errorName: "Error", args: ["nope"]})
    expect(refusalOf(revert(data))).toEqual({reason: "unknown"})
  })

  it("says so when the wallet declines, and when it stays on another network", async () => {
    const declined = await run(press("execute"), fakeWallet({send: async () => Promise.reject({code: 4001})}))
    expect(describe(declined.at(-1)!, press("execute"))).toBe("You declined in your wallet, so nothing was sent.")

    const elsewhere = await run(press("execute"), fakeWallet({chainId: "0x1", switchError: {code: 4001}}))
    expect(describe(elsewhere.at(-1)!, press("execute"))).toBe(
      "Your wallet is on another network. Switch it to Base and press the button again.",
    )
  })

  it("calls a press still unseen when the time runs out unconfirmed, not failed", async () => {
    let clock = 0
    const updates: ActionUpdate[] = []
    await runAction(target, press("execute"), fakeWallet({receipt: () => null}), update => updates.push(update), {
      now: () => clock,
      wait: async milliseconds => void (clock += milliseconds),
    })
    expect(updates.at(-1)).toEqual({kind: "unconfirmed"})
    expect(clock).toBe(180_000)
    expect(describe(updates.at(-1)!, press("execute"))).toBe(
      "Base hasn’t included this yet, and it may still go through. Check your wallet’s activity before pressing again.",
    )
  })
})

// Vitest here runs without a document, so the hook gets the small surface it
// touches: the group's data, a click listener, its form fields, its status
// list, its wallet note and the window's wallet events.
function mountHook(
  wallet: SelectedWallet | null,
  name: string,
  {
    fields = forms[name] ?? {},
    groupData = {chainId: "8453", to: votes, signedIn: JSON.stringify([voter.toLowerCase()])},
    pressData = {},
  }: {fields?: Record<string, string>; groupData?: Record<string, string>; pressData?: Record<string, string>} = {},
) {
  let listener: ((event: Event) => void) | undefined
  let connected = wallet
  const walletListeners = new Set<() => void>()
  const dispatchEvent = vi.fn()
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
  const {assets: listed, ...data} = buttonData[name] ?? {}
  const button = {
    dataset: {fleetAction: name, ...data, ...pressData},
    disabled: false,
    closest: (selector: string) => (selector === "[data-fleet-action]" ? button : null),
    setAttribute: vi.fn(),
    toggleAttribute: vi.fn(),
  }
  const el = {
    dataset: listed ? {...groupData, assets: listed} : groupData,
    addEventListener: (_name: string, handler: (event: Event) => void) => {
      listener = handler
    },
    removeEventListener: vi.fn(),
    querySelector: (selector: string) => {
      if (selector === "[data-fleet-action-status]") return list
      if (selector === "[data-wallet-note]") return note
      const field = /^\[name="(.+)"\]$/.exec(selector)?.[1]
      return field && field in fields ? {value: fields[field]} : null
    },
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
  const presses: {target: Target; action: Press; wallet: SelectedWallet}[] = []
  const reports: ((update: ActionUpdate) => void)[] = []
  const hook = fleetActionHook(
    () => connected,
    async (to, action, pressedWallet, report) => {
      presses.push({target: to, action, wallet: pressedWallet})
      reports.push(report)
      await new Promise(() => undefined)
    },
  )
  const context = {el}
  hook.mounted!.call(context)
  return {
    press: () => listener!({target: button} as unknown as Event),
    presses,
    reports,
    entries,
    button,
    note,
    dispatchEvent,
    connect: (next: SelectedWallet | null) => {
      connected = next
      for (const changed of walletListeners) changed()
    },
    watching: () => walletListeners.size,
    destroy: () => hook.destroyed!.call(context),
  }
}

group("the proposal pages' wallet buttons", () => {
  afterEach(() => vi.unstubAllGlobals())

  it.each(["vote", "execute", "propose_decision", "propose_pay", "propose_launch", "delegate", "clear_delegate", "send_share"])(
    "%s reaches the wallet on every press, however many are still pending",
    name => {
      const hook = mountHook(fakeWallet(), name)

      hook.press()
      hook.press()
      hook.press()

      expect(hook.presses).toHaveLength(3)
      expect(hook.presses[2].action).toEqual(press(name))
      expect(hook.presses[2].target).toEqual(target)
      expect(hook.entries).toHaveLength(3)
      expect(hook.button.disabled).toBe(false)
      expect(hook.button.setAttribute).not.toHaveBeenCalled()
      expect(hook.button.toggleAttribute).not.toHaveBeenCalled()
    },
  )

  it("asks for a wallet when none is connected", () => {
    const hook = mountHook(null, "vote")

    hook.press()

    expect(hook.presses).toHaveLength(0)
    expect(hook.dispatchEvent.mock.calls[0][0].type).toBe("ash:wallet-connect")
    expect(hook.entries[0].textContent).toBe("Connect a wallet, then press the button again.")
  })

  it("says what to fix in the form, and sends nothing", () => {
    const hook = mountHook(fakeWallet(), "delegate", {fields: {delegate: "someone"}})
    hook.press()

    expect(hook.presses).toHaveLength(0)
    expect(hook.entries[0].textContent).toBe(
      "The wallet to vote for you isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers.",
    )
    expect(hook.entries[0].dataset.tone).toBe("error")
  })

  it.each([
    ["where the button sends", "execute", {groupData: {chainId: "8453", to: "0x12", signedIn: "[]"}}],
    ["which way the vote goes", "vote", {pressData: {support: "maybe"}}],
    ["a form field", "propose_decision", {fields: {key: "4"}}],
  ])("asks for a refresh when %s can't be read, and sends nothing", (_what, name, options) => {
    const hook = mountHook(fakeWallet(), name, options)
    hook.press()

    expect(hook.presses).toHaveLength(0)
    expect(hook.entries[0].textContent).toBe(outOfDateWords)
    expect(hook.entries[0].dataset.tone).toBe("error")
  })

  it("shows each press's progress, and a refusal as an error", () => {
    const hook = mountHook(fakeWallet(), "execute")
    hook.press()

    hook.reports[0]({kind: "switching"})
    expect(hook.entries[0].textContent).toBe("Switching your wallet to Base…")
    expect(hook.entries[0].dataset.tone).toBe("info")

    hook.reports[0]({kind: "wallet"})
    expect(hook.entries[0].textContent).toBe("Carrying out proposal 5. Confirm in your wallet.")
    expect(hook.entries[0].dataset.tone).toBe("info")

    hook.reports[0]({kind: "unconfirmed"})
    expect(hook.entries[0].dataset.tone).toBe("info")

    hook.reports[0]({kind: "failed", reason: "not_passed"})
    expect(hook.entries[0].textContent).toBe("This proposal didn’t pass, so it can’t be carried out.")
    expect(hook.entries[0].dataset.tone).toBe("error")
  })

  it("keeps the latest five presses on show", () => {
    const hook = mountHook(fakeWallet(), "send_share")
    for (let count = 0; count < 7; count++) hook.press()

    expect(hook.presses).toHaveLength(7)
    expect(hook.entries).toHaveLength(5)
  })

  it.each(["vote", "execute", "propose_decision", "propose_pay", "propose_launch", "delegate", "clear_delegate", "send_share"])(
    "%s names both wallets when the connected one isn't the signed-in one, and still reaches the connected one",
    name => {
      const connected = fakeWallet()
      const hook = mountHook(connected, name, {
        groupData: {chainId: "8453", to: votes, signedIn: JSON.stringify([signedIn, `0x${"3".repeat(40)}`])},
      })

      expect(hook.note.textContent).toBe(
        "You’re signed in as 0x5555…5555 but your wallet is on 0x1111…1111. Presses here go to 0x1111…1111.",
      )

      hook.press()
      hook.press()
      expect(hook.presses.map(pressed => pressed.wallet)).toEqual([connected, connected])
      expect(hook.button.disabled).toBe(false)
      expect(hook.button.setAttribute).not.toHaveBeenCalled()
      expect(hook.button.toggleAttribute).not.toHaveBeenCalled()
    },
  )

  it("says nothing about wallets when the connected one is any of the signed-in person's", () => {
    const hook = mountHook(fakeWallet(), "vote", {
      groupData: {chainId: "8453", to: votes, signedIn: JSON.stringify([signedIn, voter.toLowerCase()])},
    })
    expect(hook.note.textContent).toBe("")
  })

  it("updates the note as the connected wallet changes, and stops watching once it has left", () => {
    const hook = mountHook(null, "vote", {groupData: {chainId: "8453", to: votes, signedIn: JSON.stringify([signedIn])}})
    expect(hook.note.textContent).toBe("")

    hook.connect(fakeWallet())
    expect(hook.note.textContent).toMatch(/^You’re signed in as 0x5555…5555/)

    hook.connect({...fakeWallet(), address: signedIn})
    expect(hook.note.textContent).toBe("")

    hook.destroy()
    expect(hook.watching()).toBe(0)
  })

  it("says nothing about wallets to someone signed out", () => {
    const hook = mountHook(fakeWallet(), "vote", {groupData: {chainId: "8453", to: votes, signedIn: "[]"}})
    expect(hook.note.textContent).toBe("")
  })

  it("asks for a refresh in the note when the signed-in wallets can't be read, and still sends", () => {
    const hook = mountHook(fakeWallet(), "execute", {groupData: {chainId: "8453", to: votes, signedIn: "[\"0x12\"]"}})
    expect(hook.note.textContent).toBe(unreadableSignedInWords)

    hook.press()
    expect(hook.presses).toHaveLength(1)
  })
})
