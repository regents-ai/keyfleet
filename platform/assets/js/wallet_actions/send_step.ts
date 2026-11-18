import type {Address, Hash, Hex} from "viem"

import type {EthereumProvider, SelectedWallet} from "./connected_wallet"

/**
 * The chain a step goes to. The server's review also names it and its public
 * node; the wallet takes those from Privy's own list of networks instead.
 */
export type StepChain = {chain_id: number}

/** One transaction a button sends, built on the server. */
export type TransactionStep = {kind: "transaction"; step: string; to: Address; data: Hex; value: Hex}

/** One EIP-712 signature a button asks for, built on the server. */
export type SignatureStep = {kind: "signature"; step: string; typed_data: Record<string, unknown>}

export type Step = TransactionStep | SignatureStep

/** Nothing reached the wallet's send; the reason picks the words the server shows. */
export class NothingSent extends Error {
  constructor(readonly reason: "step_unknown" | "wallet_unavailable" | "switch_declined" | "network_mismatch") {
    super(reason)
  }
}

export type Failure = NothingSent["reason"] | "wallet_declined" | "insufficient_funds" | "send_unconfirmed"

/**
 * Sends one transaction through `wallet`, from the signer the server built the
 * step for. A wallet on another chain is first asked to switch to the step's.
 *
 * A wallet that says it appends a builder code itself (ERC-5792's `dataSuffix`,
 * the way a smart wallet credits one) is sent the step with `wallet_sendCalls`:
 * the step's data without its code, and the code for the wallet to append, so
 * the code is on the chain once. Every other wallet gets `eth_sendTransaction`,
 * and so does one that does not answer in time or whose calls this page cannot
 * follow. Either way one press makes one send, and the answer is one
 * transaction hash.
 */
export async function sendStep(
  chain: StepChain,
  signer: Address,
  step: TransactionStep,
  wallet: SelectedWallet,
  sending: () => void,
): Promise<Hash> {
  const chainId: Hex = `0x${chain.chain_id.toString(16)}`
  const provider = await ready(chain, wallet)
  const calls = await callsPath(provider, chainId, signer, step.data)

  sending()
  if (calls) return sendCall(provider, chainId, signer, step, calls.suffix, calls.wait)
  const hash = await provider.request({
    method: "eth_sendTransaction",
    params: [{
      from: signer,
      to: step.to,
      data: step.data,
      value: step.value,
      // The step's chain, for a wallet that sends only on the chain it is given.
      chainId,
    }],
  })
  if (typeof hash !== "string" || !transactionHash.test(hash)) {
    throw new Error("The wallet did not return a transaction hash.")
  }
  return hash as Hash
}

const transactionHash = /^0x[0-9a-fA-F]{64}$/

// ERC-8021's marker, the last 16 bytes of every builder-code suffix.
const marker = "80218021802180218021802180218021"

/**
 * The ERC-8021 schema 0 suffix that ends `data`: the codes, their length in one
 * byte, the schema id `00`, then the marker. Null unless the data ends with a
 * whole one.
 */
export function builderCodeSuffix(data: string): Hex | null {
  const tail = `00${marker}`
  if (!/^0x(?:[0-9a-f]{2})*$/i.test(data) || !data.toLowerCase().endsWith(tail)) return null
  const end = data.length - tail.length
  // No room for the length byte.
  if (end < 4) return null
  const start = end - 2 - 2 * Number.parseInt(data.slice(end - 2, end), 16)
  return start >= 2 ? `0x${data.slice(start)}` : null
}

// How long deciding how to send may take: the wallet saying what it can do,
// then the load of the code that follows its calls. A wallet that answers at
// all answers from what it already holds; past this the step is sent as a
// transaction, so every press reaches the wallet.
const callsPathWaitMs = 2_000

type CallsWait = (provider: EthereumProvider, id: string) => Promise<unknown>

/**
 * The suffix ending the step's data and the wait for the wallet's calls, when
 * the wallet says it appends a suffix for the signer on this chain (ERC-5792
 * `wallet_getCapabilities`; a capability under `0x0` holds on every chain) and
 * its calls can be followed here. Null when the data has no suffix, when the
 * wallet does not know the method, refuses it or does not say so, when the wait
 * cannot be loaded, or when all this takes longer than `callsPathWaitMs`: the
 * step is then sent as a transaction.
 */
async function callsPath(
  provider: EthereumProvider,
  chainId: Hex,
  signer: Address,
  data: Hex,
): Promise<{suffix: Hex; wait: CallsWait} | null> {
  const suffix = builderCodeSuffix(data)
  if (!suffix) return null
  let timer: ReturnType<typeof setTimeout> | undefined
  const late = new Promise<null>(resolve => {
    timer = setTimeout(() => resolve(null), callsPathWaitMs)
  })
  try {
    const asked = provider.request({method: "wallet_getCapabilities", params: [signer, [chainId]]})
    const answer = await Promise.race([asked, late])
    if (![chainId, "0x0"].some(id => appendsSuffix(answer, id))) return null
    const wait = await Promise.race([callsWait(), late])
    return wait && {suffix, wait}
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

/**
 * viem's wait for a wallet's calls, loaded before the wallet is asked to send,
 * so a call it sends can always be followed. Loaded at a press rather than with
 * the page: Privy's code already carries viem, so the page's first load stays as
 * it was. Null when it cannot be loaded, as on a page left open across a release.
 */
async function callsWait(): Promise<CallsWait | null> {
  try {
    const [{createClient, custom}, {waitForCallsStatus}] = await Promise.all([import("viem"), import("viem/actions")])
    return async (provider, id) => {
      // Base makes a block every two seconds; viem would read every second for it.
      const client = createClient({transport: custom(provider), pollingInterval: 1_000})
      const {receipts} = await waitForCallsStatus(client, {id})
      return receipts?.[0]?.transactionHash
    }
  } catch {
    return null
  }
}

function appendsSuffix(capabilities: unknown, chainId: string): boolean {
  const forChain = (capabilities as Record<string, {dataSuffix?: {supported?: unknown}} | undefined> | null)?.[chainId]
  return forChain?.dataSuffix?.supported === true
}

/**
 * Sends the step as the one call of `wallet_sendCalls`: the data the server
 * built with `suffix` taken off its end, and `suffix` for the wallet to append
 * to what it submits, as Base asks, so the two together are the server's data
 * and the code is there once. The wallet answers an id; `wait` reads the calls'
 * status until the wallet says they are done, and the answer is the hash of the
 * transaction that included them, reverted or not. A wait that ends with none
 * leaves the outcome to the wallet.
 */
async function sendCall(
  provider: EthereumProvider,
  chainId: Hex,
  signer: Address,
  step: TransactionStep,
  suffix: Hex,
  wait: CallsWait,
): Promise<Hash> {
  const data = step.data.slice(0, step.data.length - (suffix.length - 2)) as Hex
  const answer = await provider.request({
    method: "wallet_sendCalls",
    params: [{
      version: "2.0.0",
      chainId,
      from: signer,
      // One call is atomic already; requiring it would make a wallet that can't batch refuse, or ask to upgrade.
      atomicRequired: false,
      calls: [{to: step.to, data, value: step.value}],
      capabilities: {dataSuffix: {value: suffix, optional: true}},
    }],
  })
  const id = (answer as {id?: unknown} | null)?.id
  if (typeof id !== "string") throw new Error("The wallet did not return an id for the calls.")

  const hash = await wait(provider, id)
  if (typeof hash !== "string" || !transactionHash.test(hash)) {
    throw new Error("The wallet's calls ended without a transaction.")
  }
  return hash as Hash
}

/**
 * Asks `wallet` to sign the server's typed data as the signer, after the same
 * chain switch as a send. Returns the signature only; the server keeps the
 * typed data it built.
 */
export async function signStep(
  chain: StepChain,
  signer: Address,
  step: SignatureStep,
  wallet: SelectedWallet,
  sending: () => void,
): Promise<Hex> {
  const provider = await ready(chain, wallet)

  sending()
  const signature = await provider.request({
    method: "eth_signTypedData_v4",
    params: [signer, JSON.stringify(step.typed_data)],
  })
  if (typeof signature !== "string" || !/^0x[0-9a-fA-F]{130}$/.test(signature)) {
    throw new Error("The wallet did not return a signature.")
  }
  return signature as Hex
}

/** Why a press ended without a hash. After `sending`, the wallet may have sent it. */
export function failure(sending: boolean, error: unknown): Failure {
  if (!sending) return error instanceof NothingSent ? error.reason : "wallet_unavailable"
  if (hasCode(error, 4001)) return "wallet_declined"
  // No EIP-1193 code names this; wallets and nodes all say it in these words.
  return hasMessage(error, /insufficient funds/i) ? "insufficient_funds" : "send_unconfirmed"
}

// A wallet on another chain is asked to switch to the step's on every press,
// through its own switch (privy_bridge.tsx), and once that switch resolves the
// press goes on. When the wallet declines or fails the switch, this press
// sends nothing and the next press asks again.
async function ready(chain: StepChain, {provider, switchChain}: SelectedWallet): Promise<EthereumProvider> {
  if ((await chainId(provider)) !== chain.chain_id) {
    await switchChain(chain.chain_id).catch((error: unknown) => {
      throw new NothingSent(hasCode(error, 4001) ? "switch_declined" : "network_mismatch")
    })
  }
  return provider
}

/** The chain the wallet is on now; -1 when it does not say. */
async function chainId(provider: EthereumProvider): Promise<number> {
  const value = await provider.request({method: "eth_chainId"})
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value) ? Number(BigInt(value)) : -1
}

// Wallets wrap the EIP-1193 error in `cause` chains of their own.
function hasCode(error: unknown, code: number): boolean {
  return causes(error).some(e => (e as {code?: unknown}).code === code)
}

function hasMessage(error: unknown, words: RegExp): boolean {
  return causes(error).some(e => {
    const message = (e as {message?: unknown}).message
    return typeof message === "string" && words.test(message)
  })
}

function causes(error: unknown): object[] {
  const chain: object[] = []
  for (let e = error; e && typeof e === "object" && chain.length < 8; e = (e as {cause?: unknown}).cause) chain.push(e)
  return chain
}
