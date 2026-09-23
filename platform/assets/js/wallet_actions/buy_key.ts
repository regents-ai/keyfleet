import {
  decodeErrorResult,
  decodeEventLog,
  encodeFunctionData,
  getAddress,
  parseAbi,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
} from "viem"
import {base} from "viem/chains"

import type {EthereumProvider, SelectedWallet} from "./connected_wallet"

/** The parts of `contracts/src/Keyfleet.sol` a purchase touches. */
export const keyfleetAbi = parseAbi([
  "function purchase(address receiver, address referrer, uint256 maxPrice, uint256 deadline) returns (uint256 tokenId)",
  "event Purchased(uint256 indexed tokenId, address indexed buyer, address indexed receiver, address referrer, uint256 gross, uint256 protocol, uint256 referral, uint256 capital, uint256 reserve, uint256 rebate)",
  "error Expired(uint256 deadline)",
  "error PriceAboveMax(uint256 price, uint256 maxPrice)",
  "error SoldOut()",
  "error HoldingLimitExceeded(address account, uint256 level, uint256 limit)",
])

// Solidity's own revert with a reason, which is how Base USDC refuses a transfer.
const revertAbi = [...keyfleetAbi, ...parseAbi(["error Error(string reason)"])]

export const usdcAbi = parseAbi([
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
])

/** What the fleet page offers: the next key's price and where it is paid. */
export type KeyOrder = Readonly<{
  chainId: number
  fleet: Address
  usdc: Address
  price: bigint
  priceLabel: string
  referrer: Address
  deadlineSeconds: bigint
}>

export type BuyStep = "approve" | "purchase"

export type BuyFailure =
  | {reason: "price_moved" | "sold_out" | "expired" | "not_enough_usdc" | "allowance_used"}
  | {reason: "holding_limit"; level: bigint; limit: bigint}
  | {reason: "wrong_network" | "rejected" | "approval_failed" | "unconfirmed" | "unknown"}

export type BuyUpdate =
  | {kind: "connect"}
  | {kind: "wallet"; step: BuyStep}
  | {kind: "sent"; step: BuyStep; hash: Hex}
  | {kind: "bought"; tokenId: bigint; hash: Hex}
  | ({kind: "failed"} & BuyFailure)

export type BuyTiming = {
  now?: () => number
  wait?: (milliseconds: number) => Promise<void>
  pollMs?: number
  receiptTimeoutMs?: number
}

type Receipt = {status: string; blockNumber: Hex; logs: {address: string; topics: Hex[]; data: Hex}[]}

class Failure extends Error {
  constructor(readonly failure: BuyFailure) {
    super(failure.reason)
  }
}

/**
 * Reads the order the fleet page rendered, and throws when it can't: a page
 * whose order can't be read is out of date, and that is the only thing that
 * stops a press before the wallet. `getAddress` refuses anything that isn't an
 * address.
 */
export function readKeyOrder(data: Readonly<Record<string, string | undefined>>): KeyOrder {
  const {chainId, fleet = "", usdc = "", price, priceLabel, referrer = "", deadlineSeconds} = data
  if (
    !chainId || !/^[1-9]\d*$/.test(chainId) ||
    !price || !/^[1-9]\d*$/.test(price) ||
    !priceLabel ||
    !deadlineSeconds || !/^[1-9]\d*$/.test(deadlineSeconds)
  ) {
    throw new Error("unreadable order")
  }

  return Object.freeze({
    chainId: Number(chainId),
    fleet: getAddress(fleet),
    usdc: getAddress(usdc),
    price: BigInt(price),
    priceLabel,
    referrer: referrer === "" ? zeroAddress : getAddress(referrer),
    deadlineSeconds: BigInt(deadlineSeconds),
  })
}

/** What the page says when its order can't be read. */
export const outOfDateWords = "This page is out of date. Refresh it and press Buy again."

/**
 * Buys the next key with the wallet: approves exactly the price when the
 * wallet's USDC allowance to the fleet is below it, then buys for the wallet
 * itself. Every call runs on its own, so a second press while a first is
 * pending sends its own requests to the wallet.
 */
export async function buyKey(
  order: KeyOrder,
  wallet: SelectedWallet,
  report: (update: BuyUpdate) => void,
  {
    now = Date.now,
    wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
    pollMs = 1_000,
    receiptTimeoutMs = 180_000,
  }: BuyTiming = {},
): Promise<void> {
  const buyer = getAddress(wallet.address)
  const {provider} = wallet
  const confirmation = {now, wait, pollMs, receiptTimeoutMs}

  try {
    await onChain(provider, order.chainId)

    if ((await allowance(provider, order, buyer)) < order.price) {
      report({kind: "wallet", step: "approve"})
      const approval = await send(provider, order, buyer, order.usdc, encodeFunctionData({
        abi: usdcAbi,
        functionName: "approve",
        args: [order.fleet, order.price],
      }))
      report({kind: "sent", step: "approve", hash: approval})
      const approved = await confirmed(provider, approval, confirmation)
      if (approved.status !== "0x1") throw new Failure({reason: "approval_failed"})
    }

    // The deadline counts from Base's own clock, so a wallet's computer
    // running fast or slow doesn't shorten or stretch it.
    const deadline = (await latestBlockTime(provider)) + order.deadlineSeconds
    const data = encodeFunctionData({
      abi: keyfleetAbi,
      functionName: "purchase",
      args: [buyer, order.referrer, order.price, deadline],
    })
    report({kind: "wallet", step: "purchase"})
    const purchase = await send(provider, order, buyer, order.fleet, data)
    report({kind: "sent", step: "purchase", hash: purchase})
    const receipt = await confirmed(provider, purchase, confirmation)

    if (receipt.status === "0x1") {
      report({kind: "bought", tokenId: purchasedKey(receipt, order.fleet), hash: purchase})
    } else {
      report({kind: "failed", ...(await whyReverted(provider, buyer, order.fleet, data, receipt.blockNumber))})
    }
  } catch (error) {
    report({kind: "failed", ...failureOf(error)})
  }
}

/** The key a successful purchase minted, from the fleet's `Purchased` event. */
export function purchasedKey(receipt: Pick<Receipt, "logs">, fleet: Address): bigint {
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== fleet.toLowerCase()) continue
    try {
      const event = decodeEventLog({abi: keyfleetAbi, eventName: "Purchased", topics: log.topics as [Hex, ...Hex[]], data: log.data})
      return event.args.tokenId
    } catch {
      continue
    }
  }
  throw new Failure({reason: "unknown"})
}

/**
 * What went wrong, from the wallet's answer: the exact rejection code a
 * wallet gives when its user declines, or the revert the fleet or USDC
 * returned. Anything else is unknown.
 */
export function failureOf(error: unknown): BuyFailure {
  if (error instanceof Failure) return error.failure
  if (hasCode(error, 4001)) return {reason: "rejected"}

  for (const data of revertData(error)) {
    const failure = revertFailure(data)
    if (failure) return failure
  }
  return {reason: "unknown"}
}

function revertFailure(data: Hex): BuyFailure | null {
  let decoded
  try {
    decoded = decodeErrorResult({abi: revertAbi, data})
  } catch {
    return null
  }

  switch (decoded.errorName) {
    case "PriceAboveMax":
      return {reason: "price_moved"}
    case "SoldOut":
      return {reason: "sold_out"}
    case "Expired":
      return {reason: "expired"}
    case "HoldingLimitExceeded":
      return {reason: "holding_limit", level: decoded.args[1], limit: decoded.args[2]}
    case "Error": {
      const [message] = decoded.args
      if (message === "ERC20: transfer amount exceeds balance") return {reason: "not_enough_usdc"}
      if (message === "ERC20: transfer amount exceeds allowance") return {reason: "allowance_used"}
      return null
    }
    default:
      return null
  }
}

// A revert reaches the page wrapped however the wallet wraps it, so every
// hex `data` value in the error is a candidate; only one that decodes as one
// of the errors above is taken to be the revert.
function revertData(error: unknown): Hex[] {
  const found: Hex[] = []
  const seen = new Set<unknown>()
  const visit = (value: unknown, depth: number): void => {
    if (depth > 6 || !value || typeof value !== "object" || seen.has(value)) return
    seen.add(value)
    for (const key of new Set([...Object.keys(value), "cause", "data", "error"])) {
      let child: unknown
      try {
        child = Reflect.get(value, key)
      } catch {
        continue
      }
      if (key === "data" && typeof child === "string" && /^0x[0-9a-fA-F]{8,}$/.test(child)) {
        found.push(child as Hex)
      } else {
        visit(child, depth + 1)
      }
    }
  }
  visit(error, 0)
  return found
}

// A wallet's error code, however many times a library has wrapped it: 4001
// when its user declines, 4902 when it doesn't know the network asked for.
function hasCode(error: unknown, code: number): boolean {
  const seen = new Set<unknown>()
  let current: unknown = error
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current)
    if (Reflect.get(current, "code") === code) return true
    current = Reflect.get(current, "cause") ?? Reflect.get(current, "error")
  }
  return false
}

async function onChain(provider: EthereumProvider, chainId: number): Promise<void> {
  if ((await chainOf(provider)) === chainId) return
  try {
    await switchTo(provider, chainId)
  } catch {
    throw new Failure({reason: "wrong_network"})
  }
  if ((await chainOf(provider)) !== chainId) throw new Failure({reason: "wrong_network"})
}

// A wallet that has never been on Base is asked to add it, then to move to it.
async function switchTo(provider: EthereumProvider, chainId: number): Promise<void> {
  const change = {method: "wallet_switchEthereumChain", params: [{chainId: toHex(chainId)}]}
  try {
    await provider.request(change)
  } catch (error) {
    if (chainId !== base.id || !hasCode(error, 4902)) throw error
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: toHex(base.id),
          chainName: base.name,
          nativeCurrency: base.nativeCurrency,
          rpcUrls: base.rpcUrls.default.http,
          blockExplorerUrls: [base.blockExplorers.default.url],
        },
      ],
    })
    await provider.request(change)
  }
}

async function chainOf(provider: EthereumProvider): Promise<number> {
  const chainId = await provider.request({method: "eth_chainId"})
  if (typeof chainId !== "string" || !/^0x[0-9a-fA-F]+$/.test(chainId)) throw new Failure({reason: "unknown"})
  return Number(BigInt(chainId))
}

async function latestBlockTime(provider: EthereumProvider): Promise<bigint> {
  const block = await provider.request({method: "eth_getBlockByNumber", params: ["latest", false]})
  const timestamp = block && typeof block === "object" ? Reflect.get(block, "timestamp") : undefined
  if (typeof timestamp !== "string" || !/^0x[0-9a-fA-F]+$/.test(timestamp)) throw new Failure({reason: "unknown"})
  return BigInt(timestamp)
}

async function allowance(provider: EthereumProvider, order: KeyOrder, buyer: Address): Promise<bigint> {
  const result = await provider.request({
    method: "eth_call",
    params: [
      {
        to: order.usdc,
        data: encodeFunctionData({abi: usdcAbi, functionName: "allowance", args: [buyer, order.fleet]}),
      },
      "latest",
    ],
  })
  if (typeof result !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(result)) throw new Failure({reason: "unknown"})
  return BigInt(result)
}

// The chain id travels with the transaction, so a wallet that has moved to
// another network since the check above refuses it rather than sending it there.
async function send(provider: EthereumProvider, order: KeyOrder, from: Address, to: Address, data: Hex): Promise<Hex> {
  const hash = await provider.request({
    method: "eth_sendTransaction",
    params: [{from, to, data, value: "0x0", chainId: toHex(order.chainId)}],
  })
  if (typeof hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Failure({reason: "unconfirmed"})
  return hash as Hex
}

// Base's first block with the transaction in it is the confirmation; nothing
// waits for finality. A failed read is asked again until the time runs out,
// and a transaction still unseen then is reported as unconfirmed, never as
// failed, since it may still land.
async function confirmed(
  provider: EthereumProvider,
  hash: Hex,
  {now, wait, pollMs, receiptTimeoutMs}: Required<BuyTiming>,
): Promise<Receipt> {
  const until = now() + receiptTimeoutMs
  for (;;) {
    const receipt = await provider
      .request({method: "eth_getTransactionReceipt", params: [hash]})
      .catch(() => null)
    if (isReceipt(receipt)) return receipt
    if (now() >= until) throw new Failure({reason: "unconfirmed"})
    await wait(pollMs)
  }
}

function isReceipt(value: unknown): value is Receipt {
  if (!value || typeof value !== "object") return false
  const receipt = value as Partial<Receipt>
  return typeof receipt.status === "string" && typeof receipt.blockNumber === "string" && Array.isArray(receipt.logs)
}

// A receipt says only that the purchase reverted, so the same call is asked of
// the block it landed in to learn why.
async function whyReverted(
  provider: EthereumProvider,
  from: Address,
  to: Address,
  data: Hex,
  block: Hex,
): Promise<BuyFailure> {
  try {
    await provider.request({method: "eth_call", params: [{from, to, data}, block]})
  } catch (error) {
    return failureOf(error)
  }
  return {reason: "unknown"}
}

/** The plain words the page shows for an update. */
export function describe(update: BuyUpdate, order: Pick<KeyOrder, "priceLabel" | "deadlineSeconds">): string {
  switch (update.kind) {
    case "connect":
      return "Connect a wallet, then press Buy again."
    case "wallet":
      return update.step === "approve"
        ? `Approve spending ${order.priceLabel} in your wallet.`
        : "Confirm the purchase in your wallet."
    case "sent":
      return update.step === "approve"
        ? "Approval sent. Waiting for Base to include it."
        : "Purchase sent. Waiting for Base to include it."
    case "bought":
      return `Confirmed. Key ${update.tokenId.toLocaleString("en-US")} is yours. It shows as yours on the map in a few seconds.`
    case "failed":
      return failureWords(update, order)
  }
}

function failureWords(failure: BuyFailure, order: Pick<KeyOrder, "priceLabel" | "deadlineSeconds">): string {
  switch (failure.reason) {
    case "price_moved":
      return "The price went up before this purchase went through, so no key was bought and no USDC was taken. Reload the page for the latest price, then press Buy again."
    case "sold_out":
      return "Every key in this fleet has now been sold."
    case "expired":
      return `The purchase took more than ${order.deadlineSeconds / 60n} minutes to reach Base, so it expired. Press Buy again.`
    case "holding_limit":
      return `Your wallet already holds as many level ${failure.level} keys as one wallet may (${failure.limit}).`
    case "not_enough_usdc":
      return `Your wallet doesn’t have enough USDC. This key costs ${order.priceLabel}.`
    case "allowance_used":
      return "The purchase couldn’t use your USDC approval, so no key was bought. Press Buy again; your wallet asks for a new approval if one is needed."
    case "wrong_network":
      return "Your wallet is on another network. Switch it to Base and press Buy again."
    case "rejected":
      return "You declined in your wallet, so no key was bought."
    case "approval_failed":
      return "The approval didn’t go through, so no key was bought. Press Buy again."
    case "unconfirmed":
      return "Base hasn’t confirmed this yet. Check your wallet’s activity before trying again."
    case "unknown":
      return "The purchase didn’t go through. Try again."
  }
}
