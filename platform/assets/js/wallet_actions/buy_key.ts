import {
  decodeErrorResult,
  decodeEventLog,
  encodeFunctionData,
  getAddress,
  parseAbi,
  zeroAddress,
  type Address,
  type Hex,
} from "viem"

import {
  confirmed,
  defaultTiming,
  hasCode,
  onChain,
  replayError,
  revertData,
  send,
  WalletStop,
  type CallTiming,
  type Receipt,
} from "./chain_call"
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
  timing: CallTiming = {},
): Promise<void> {
  const buyer = getAddress(wallet.address)
  const {provider} = wallet
  const confirmation = {...defaultTiming, ...timing}

  try {
    await onChain(provider, order.chainId)

    if ((await allowance(provider, order, buyer)) < order.price) {
      report({kind: "wallet", step: "approve"})
      const approval = await send(provider, order.chainId, buyer, order.usdc, encodeFunctionData({
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
    const purchase = await send(provider, order.chainId, buyer, order.fleet, data)
    report({kind: "sent", step: "purchase", hash: purchase})
    const receipt = await confirmed(provider, purchase, confirmation)

    if (receipt.status === "0x1") {
      report({kind: "bought", tokenId: purchasedKey(receipt, order.fleet), hash: purchase})
    } else {
      report({kind: "failed", ...failureOf(await replayError(provider, buyer, order.fleet, data, receipt.blockNumber))})
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
  if (error instanceof WalletStop) return {reason: error.reason}
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
