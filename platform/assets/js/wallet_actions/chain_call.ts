import {toHex, type Address, type Hex} from "viem"
import {base} from "viem/chains"

import type {EthereumProvider} from "./connected_wallet"

/**
 * The steps every wallet button shares: putting the wallet on the fleet's
 * network, handing it one transaction, waiting for Base's first block that
 * includes it, and asking that block why a transaction that landed failed.
 * What each button sends and how it words the answer stay with the button.
 */

export type Receipt = {status: string; blockNumber: Hex; logs: {address: string; topics: Hex[]; data: Hex}[]}

export type CallTiming = {
  now?: () => number
  wait?: (milliseconds: number) => Promise<void>
  pollMs?: number
  receiptTimeoutMs?: number
}

export type WalletStopReason = "wrong_network" | "unconfirmed" | "unknown"

/** A step that stopped before the chain answered, and why. */
export class WalletStop extends Error {
  constructor(readonly reason: WalletStopReason) {
    super(reason)
  }
}

export const defaultTiming: Required<CallTiming> = {
  now: Date.now,
  wait: milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
  pollMs: 1_000,
  receiptTimeoutMs: 180_000,
}

// A revert reaches the page wrapped however the wallet wraps it, so every
// hex `data` value in the error is a candidate; only one that decodes as one
// of the caller's errors is taken to be the revert.
export function revertData(error: unknown): Hex[] {
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
export function hasCode(error: unknown, code: number): boolean {
  const seen = new Set<unknown>()
  let current: unknown = error
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current)
    if (Reflect.get(current, "code") === code) return true
    current = Reflect.get(current, "cause") ?? Reflect.get(current, "error")
  }
  return false
}

// `switching` is told when the wallet is asked to change networks.
export async function onChain(provider: EthereumProvider, chainId: number, switching = () => {}): Promise<void> {
  if ((await chainOf(provider)) === chainId) return
  switching()
  try {
    await switchTo(provider, chainId)
  } catch {
    throw new WalletStop("wrong_network")
  }
  if ((await chainOf(provider)) !== chainId) throw new WalletStop("wrong_network")
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
  if (typeof chainId !== "string" || !/^0x[0-9a-fA-F]+$/.test(chainId)) throw new WalletStop("unknown")
  return Number(BigInt(chainId))
}

// The chain id travels with the transaction, so a wallet that has moved to
// another network since it was checked refuses it rather than sending it there.
export async function send(
  provider: EthereumProvider,
  chainId: number,
  from: Address,
  to: Address,
  data: Hex,
): Promise<Hex> {
  const hash = await provider.request({
    method: "eth_sendTransaction",
    params: [{from, to, data, value: "0x0", chainId: toHex(chainId)}],
  })
  if (typeof hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new WalletStop("unconfirmed")
  return hash as Hex
}

// Base's first block with the transaction in it is the confirmation; nothing
// waits for finality. A failed read is asked again until the time runs out,
// and a transaction still unseen then is reported as unconfirmed, never as
// failed, since it may still land.
export async function confirmed(
  provider: EthereumProvider,
  hash: Hex,
  {now, wait, pollMs, receiptTimeoutMs}: Required<CallTiming>,
): Promise<Receipt> {
  const until = now() + receiptTimeoutMs
  for (;;) {
    const receipt = await provider
      .request({method: "eth_getTransactionReceipt", params: [hash]})
      .catch(() => null)
    if (isReceipt(receipt)) return receipt
    if (now() >= until) throw new WalletStop("unconfirmed")
    await wait(pollMs)
  }
}

function isReceipt(value: unknown): value is Receipt {
  if (!value || typeof value !== "object") return false
  const receipt = value as Partial<Receipt>
  return typeof receipt.status === "string" && typeof receipt.blockNumber === "string" && Array.isArray(receipt.logs)
}

// A receipt says only that the transaction failed, so the same call is asked
// of the block it landed in to learn why. The answer is the error that call
// raised, or nothing when it raised none.
export async function replayError(
  provider: EthereumProvider,
  from: Address,
  to: Address,
  data: Hex,
  block: Hex,
): Promise<unknown> {
  try {
    await provider.request({method: "eth_call", params: [{from, to, data}, block]})
  } catch (error) {
    return error
  }
  return null
}
