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
 * Sends one transaction from the signed-in wallet. Chain and account are read
 * again on every press, and `eth_chainId` is the last read before the send, so a
 * wallet that changes network part-way is refused before it sees the transaction.
 *
 * A wallet that says it appends a builder code itself (ERC-5792's `dataSuffix`,
 * the way a smart wallet credits one) is sent the step with `wallet_sendCalls`
 * and the code from the step's own data; every other wallet gets
 * `eth_sendTransaction`. Either way one press makes one send, and the answer is
 * one transaction hash.
 */
export async function sendStep(
  chain: StepChain,
  signer: Address,
  step: TransactionStep,
  wallet: () => SelectedWallet | null,
  sending: () => void,
): Promise<Hash> {
  const chainId: Hex = `0x${chain.chain_id.toString(16)}`
  const provider = await ready(chain, signer, wallet)
  const suffix = await suffixWalletAppends(provider, chainId, signer, step.data)
  await unchanged(provider, chain, wallet)

  sending()
  if (suffix) return sendCall(provider, chainId, signer, step, suffix)
  const hash = await provider.request({
    method: "eth_sendTransaction",
    params: [{
      from: signer,
      to: step.to,
      data: step.data,
      value: step.value,
      // A wallet that checks it refuses the send if it moved off the chain after the read above.
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

/**
 * The suffix ending the step's data, when the wallet says it appends one for the
 * signer on this chain (ERC-5792 `wallet_getCapabilities`; a capability under
 * `0x0` holds on every chain). Null when the data has none, or the wallet does not
 * know the method, refuses it or does not say so: the step is then sent as a
 * transaction.
 */
async function suffixWalletAppends(
  provider: EthereumProvider,
  chainId: Hex,
  signer: Address,
  data: Hex,
): Promise<Hex | null> {
  const suffix = builderCodeSuffix(data)
  if (!suffix) return null
  try {
    const answer = await provider.request({method: "wallet_getCapabilities", params: [signer, [chainId]]})
    return [chainId, "0x0"].some(id => appendsSuffix(answer, id)) ? suffix : null
  } catch {
    return null
  }
}

function appendsSuffix(capabilities: unknown, chainId: string): boolean {
  const forChain = (capabilities as Record<string, {dataSuffix?: {supported?: unknown}} | undefined> | null)?.[chainId]
  return forChain?.dataSuffix?.supported === true
}

/**
 * Sends the step as the one call of `wallet_sendCalls`, exactly as the server
 * built it, asking the wallet to append `suffix` to what it submits. The wallet
 * answers an id; viem's wait reads the calls' status until the wallet says they
 * are done, and the answer is the hash of the transaction that included them,
 * reverted or not. A wait that ends with none leaves the outcome to the wallet.
 */
async function sendCall(
  provider: EthereumProvider,
  chainId: Hex,
  signer: Address,
  step: TransactionStep,
  suffix: Hex,
): Promise<Hash> {
  const answer = await provider.request({
    method: "wallet_sendCalls",
    params: [{
      version: "2.0.0",
      chainId,
      from: signer,
      // One call is atomic already; requiring it would make a wallet that can't batch refuse, or ask to upgrade.
      atomicRequired: false,
      calls: [{to: step.to, data: step.data, value: step.value}],
      capabilities: {dataSuffix: {value: suffix, optional: true}},
    }],
  })
  const id = (answer as {id?: unknown} | null)?.id
  if (typeof id !== "string") throw new Error("The wallet did not return an id for the calls.")

  // Loaded here rather than with the page: Privy's code already carries viem, so
  // the page's first load stays as it was.
  const [{createClient, custom}, {waitForCallsStatus}] = await Promise.all([import("viem"), import("viem/actions")])
  // Base makes a block every two seconds; viem would read every second for it.
  const client = createClient({transport: custom(provider), pollingInterval: 1_000})
  const {receipts} = await waitForCallsStatus(client, {id})
  const hash = receipts?.[0]?.transactionHash
  if (typeof hash !== "string" || !transactionHash.test(hash)) {
    throw new Error("The wallet's calls ended without a transaction.")
  }
  return hash
}

/**
 * Asks the signed-in wallet to sign the server's typed data, after the same
 * chain and account reads as a send. Returns the signature only; the server
 * keeps the typed data it built.
 */
export async function signStep(
  chain: StepChain,
  signer: Address,
  step: SignatureStep,
  wallet: () => SelectedWallet | null,
  sending: () => void,
): Promise<Hex> {
  const provider = await ready(chain, signer, wallet)

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

// The wallet is on the step's chain and account, and still the one Privy holds.
// A wallet on another chain is asked to switch on every press, through Privy's
// own switch: a person who says no hears that they did, and any other failure,
// or a wallet still elsewhere afterwards, is told to change network in the app.
async function ready(
  chain: StepChain,
  signer: Address,
  wallet: () => SelectedWallet | null,
): Promise<EthereumProvider> {
  const selected = wallet()
  if (!selected) throw new NothingSent("wallet_unavailable")
  const {provider} = selected

  if ((await chainId(provider)) !== chain.chain_id) {
    await selected.switchChain(chain.chain_id).catch((error: unknown) => {
      throw new NothingSent(hasCode(error, 4001) ? "switch_declined" : "network_mismatch")
    })
  }

  const [account] = await accounts(provider)
  // Wallets answer addresses in any letter case.
  if (account?.toLowerCase() !== signer.toLowerCase()) throw new NothingSent("wallet_unavailable")
  await unchanged(provider, chain, wallet)
  return provider
}

// The wallet is still on the step's chain, read last before a send, and still the one Privy holds.
async function unchanged(
  provider: EthereumProvider,
  chain: StepChain,
  wallet: () => SelectedWallet | null,
): Promise<void> {
  if ((await chainId(provider)) !== chain.chain_id) throw new NothingSent("network_mismatch")
  // Privy may have swapped the wallet during the reads; this check makes no request.
  if (wallet()?.provider !== provider) throw new NothingSent("wallet_unavailable")
}

/** The chain the wallet is on now; -1 when it does not say. */
async function chainId(provider: EthereumProvider): Promise<number> {
  const value = await provider.request({method: "eth_chainId"})
  return typeof value === "string" && /^0x[0-9a-f]+$/i.test(value) ? Number(BigInt(value)) : -1
}

async function accounts(provider: EthereumProvider): Promise<string[]> {
  const value = await provider.request({method: "eth_accounts"})
  return Array.isArray(value) ? value.filter((a): a is string => typeof a === "string") : []
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
