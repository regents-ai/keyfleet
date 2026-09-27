import {
  decodeErrorResult,
  encodeFunctionData,
  formatUnits,
  getAddress,
  isAddress,
  maxUint128,
  maxUint256,
  parseAbi,
  zeroAddress,
  zeroHash,
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
  type WalletStopReason,
} from "./chain_call"
import type {SelectedWallet} from "./connected_wallet"
import {shortAddress} from "./signed_in"

/** The parts of `contracts/src/KeyfleetVotes.sol` the proposal buttons call. */
export const votesAbi = parseAbi([
  "struct LaunchEnvelope { string name; string symbol; string description; string website; string image; uint128 requiredRegentRaised; bytes32 narrativeDigest; }",
  "function vote(uint256 proposalId, uint256[] tokenIds, bool support)",
  "function execute(uint256 proposalId)",
  "function proposeDecision(uint256 tokenId, string text, bytes32 digest) returns (uint256 proposalId)",
  "function proposePay(uint256 tokenId, address asset, uint256 amount, address recipient, string text, bytes32 digest) returns (uint256 proposalId)",
  "function proposeAutolaunch(uint256 tokenId, LaunchEnvelope envelope) returns (uint256 proposalId)",
  "function setVotingDelegate(address delegate)",
])

/** The part of `contracts/src/Keyfleet.sol` the stakers' share button calls. */
export const fleetAbi = parseAbi(["function sendProtocolShare() returns (uint256 amount)"])

// Every refusal the two contracts give these calls, by name: the vote
// contract's own, and the fleet's that come back through it.
const refusalAbi = parseAbi([
  "error ZeroAddress()",
  "error ZeroAmount()",
  "error RecipientNotAllowed(address recipient)",
  "error UnknownProposal(uint256 proposalId)",
  "error LaunchNotYetEligible(uint256 minted, uint256 required)",
  "error KeyNotEligible(uint256 tokenId)",
  "error NotAuthorizedForKey(uint256 tokenId, address owner)",
  "error AlreadyVoted(uint256 tokenId)",
  "error NoKeys()",
  "error AlreadyExecuted()",
  "error NotApproved(uint256 yesVotes, uint256 totalMinted)",
  "error EmptyMetadataField(uint256 field)",
  "error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found)",
  "error RaiseOutOfBounds(uint128 requiredRegentRaised)",
  "error LaunchAlreadyCreated()",
  "error AboveYesShare(address asset, uint256 amount, uint256 most)",
  "error StakingRegistrationFailed(uint256 amount, uint256 received)",
])

export type LaunchEnvelope = {
  name: string
  symbol: string
  description: string
  website: string
  image: string
  requiredRegentRaised: bigint
  narrativeDigest: Hex
}

/**
 * One press, as the contract will be asked it, with the words that name an
 * amount in it as the person will confirm it.
 */
export type Press =
  | {kind: "vote"; proposal: bigint; keys: bigint[]; support: boolean}
  | {kind: "execute"; proposal: bigint}
  | {kind: "propose_decision"; key: bigint; text: string; digest: Hex}
  | {
      kind: "propose_pay"
      key: bigint
      asset: Address
      amount: bigint
      amountWords: string
      recipient: Address
      text: string
      digest: Hex
    }
  | {kind: "propose_launch"; key: bigint; envelope: LaunchEnvelope; raiseWords: string}
  | {kind: "delegate"; delegate: Address}
  | {kind: "send_share"}

/** Where the page says a press goes: the fleet's network and one of its contracts. */
export type Target = Readonly<{chainId: number; to: Address}>

export type Refusal =
  | {
      reason:
        | "no_keys"
        | "unknown_proposal"
        | "already_executed"
        | "not_passed"
        | "above_yes_share"
        | "launch_exists"
        | "zero_asset"
        | "zero_amount"
        | "recipient_not_allowed"
        | "raise_out_of_bounds"
        | "staking_refused"
    }
  | {reason: "key_not_eligible" | "already_voted"; key: bigint}
  | {reason: "not_authorized"; key: bigint; owner: Address}
  | {reason: "launch_not_yet"; minted: bigint; required: bigint}
  | {reason: "empty_field"; field: bigint}
  | {reason: "field_too_long"; field: bigint; maximum: bigint; found: bigint}
  | {reason: Exclude<WalletStopReason, "unconfirmed"> | "rejected"}

export type ActionUpdate =
  | {kind: "connect"}
  | {kind: "switching"}
  | {kind: "wallet"}
  | {kind: "sent"; hash: Hex}
  | {kind: "done"; hash: Hex}
  | {kind: "unconfirmed"}
  | ({kind: "failed"} & Refusal)

/** A form entry that can't be put into the call, with what to say about it. */
export class Unreadable extends Error {}

/** What the page says when where a press goes can't be read. */
export const outOfDateWords = "This page is out of date. Refresh it and press the button again."

// REGENT, which a launch raises, has eighteen decimals.
const regentDecimals = 18

// The order the launch contract numbers its fields in.
const launchFields = ["name", "symbol", "description", "website", "image"] as const

/**
 * Reads where the page's buttons send, and throws when it can't: a page
 * whose contract can't be read is out of date.
 */
export function readTarget(data: Readonly<Record<string, string | undefined>>): Target {
  const {chainId, to} = data
  if (!chainId || !/^[1-9]\d*$/.test(chainId) || !to || !isAddress(to)) throw new Error("unreadable target")
  return Object.freeze({chainId: Number(chainId), to: getAddress(to)})
}

/**
 * Reads the press named `name` from the page's `data` and the form's
 * `field`s. An entry that can't be put into the call at all throws
 * `Unreadable` with plain words; anything the call can carry is carried,
 * and the contract decides.
 */
export function readAction(
  name: string | undefined,
  data: Readonly<Record<string, string | undefined>>,
  field: (name: string) => string,
): Press {
  switch (name) {
    case "vote":
      return {kind: "vote", proposal: number(data.proposal), keys: keyList(field("keys")), support: support(data.support)}
    case "execute":
      return {kind: "execute", proposal: number(data.proposal)}
    case "propose_decision":
      return {kind: "propose_decision", key: proposingKey(field("key")), text: field("text"), digest: documentCode(field("digest"))}
    case "propose_pay": {
      const asset = address(field("asset"), "The token to pay")
      const {decimals, unit} = assetOf(data.assets, asset)
      const paid = amount(field("amount"), decimals, maxUint256)
      return {
        kind: "propose_pay",
        key: proposingKey(field("key")),
        asset,
        amount: paid,
        amountWords: `${units(paid, decimals)} ${unit}`,
        recipient: address(field("recipient"), "The wallet to pay"),
        text: field("text"),
        digest: documentCode(field("digest")),
      }
    }
    case "propose_launch": {
      const raise = amount(field("raise"), regentDecimals, maxUint128)
      return {
        kind: "propose_launch",
        key: proposingKey(field("key")),
        envelope: {
          name: field("name"),
          symbol: field("symbol"),
          description: field("description"),
          website: field("website"),
          image: field("image"),
          requiredRegentRaised: raise,
          narrativeDigest: documentCode(field("digest")),
        },
        raiseWords: `${units(raise, regentDecimals)} REGENT`,
      }
    }
    case "delegate":
      return {kind: "delegate", delegate: address(field("delegate"), "The wallet to vote for you")}
    case "clear_delegate":
      return {kind: "delegate", delegate: zeroAddress}
    case "send_share":
      return {kind: "send_share"}
    default:
      throw new Error("unreadable action")
  }
}

/** The call a press makes, to the contract the page named. */
export function encode(action: Press): Hex {
  switch (action.kind) {
    case "vote":
      return encodeFunctionData({abi: votesAbi, functionName: "vote", args: [action.proposal, action.keys, action.support]})
    case "execute":
      return encodeFunctionData({abi: votesAbi, functionName: "execute", args: [action.proposal]})
    case "propose_decision":
      return encodeFunctionData({
        abi: votesAbi,
        functionName: "proposeDecision",
        args: [action.key, action.text, action.digest],
      })
    case "propose_pay":
      return encodeFunctionData({
        abi: votesAbi,
        functionName: "proposePay",
        args: [action.key, action.asset, action.amount, action.recipient, action.text, action.digest],
      })
    case "propose_launch":
      return encodeFunctionData({abi: votesAbi, functionName: "proposeAutolaunch", args: [action.key, action.envelope]})
    case "delegate":
      return encodeFunctionData({abi: votesAbi, functionName: "setVotingDelegate", args: [action.delegate]})
    case "send_share":
      return encodeFunctionData({abi: fleetAbi, functionName: "sendProtocolShare"})
  }
}

/**
 * Hands one press to the wallet and reports how it goes, up to Base's first
 * block that includes it. Every call runs on its own: nothing here waits for
 * an earlier press or decides whether the contract will take this one.
 */
export async function runAction(
  target: Target,
  action: Press,
  wallet: SelectedWallet,
  report: (update: ActionUpdate) => void,
  timing: CallTiming = {},
): Promise<void> {
  const from = getAddress(wallet.address)
  const {provider} = wallet

  try {
    const data = encode(action)
    await onChain(provider, target.chainId, () => report({kind: "switching"}))
    report({kind: "wallet"})
    const hash = await send(provider, target.chainId, from, target.to, data)
    report({kind: "sent", hash})
    const receipt = await confirmed(provider, hash, {...defaultTiming, ...timing})

    if (receipt.status === "0x1") {
      report({kind: "done", hash})
    } else {
      report({kind: "failed", ...refusalOf(await replayError(provider, from, target.to, data, receipt.blockNumber))})
    }
  } catch (error) {
    report(stopped(error))
  }
}

// A transaction Base hasn't included yet may still land, so it is never
// reported as failed.
function stopped(error: unknown): ActionUpdate {
  if (!(error instanceof WalletStop)) return {kind: "failed", ...refusalOf(error)}
  return error.reason === "unconfirmed" ? {kind: "unconfirmed"} : {kind: "failed", reason: error.reason}
}

/**
 * Why the chain or the wallet refused: the rejection code a wallet gives
 * when its user declines, or the contract's own refusal. Anything else is
 * unknown.
 */
export function refusalOf(error: unknown): Refusal {
  if (hasCode(error, 4001)) return {reason: "rejected"}

  for (const data of revertData(error)) {
    const refusal = contractRefusal(data)
    if (refusal) return refusal
  }
  return {reason: "unknown"}
}

function contractRefusal(data: Hex): Refusal | null {
  let decoded
  try {
    decoded = decodeErrorResult({abi: refusalAbi, data})
  } catch {
    return null
  }

  switch (decoded.errorName) {
    case "ZeroAddress":
      return {reason: "zero_asset"}
    case "ZeroAmount":
      return {reason: "zero_amount"}
    case "RecipientNotAllowed":
      return {reason: "recipient_not_allowed"}
    case "UnknownProposal":
      return {reason: "unknown_proposal"}
    case "LaunchNotYetEligible":
      return {reason: "launch_not_yet", minted: decoded.args[0], required: decoded.args[1]}
    case "KeyNotEligible":
      return {reason: "key_not_eligible", key: decoded.args[0]}
    case "NotAuthorizedForKey":
      return {reason: "not_authorized", key: decoded.args[0], owner: decoded.args[1]}
    case "AlreadyVoted":
      return {reason: "already_voted", key: decoded.args[0]}
    case "NoKeys":
      return {reason: "no_keys"}
    case "AlreadyExecuted":
      return {reason: "already_executed"}
    case "NotApproved":
      return {reason: "not_passed"}
    case "EmptyMetadataField":
      return {reason: "empty_field", field: decoded.args[0]}
    case "MetadataFieldTooLong":
      return {reason: "field_too_long", field: decoded.args[0], maximum: decoded.args[1], found: decoded.args[2]}
    case "RaiseOutOfBounds":
      return {reason: "raise_out_of_bounds"}
    case "LaunchAlreadyCreated":
      return {reason: "launch_exists"}
    case "AboveYesShare":
      return {reason: "above_yes_share"}
    case "StakingRegistrationFailed":
      return {reason: "staking_refused"}
  }
}

/** The plain words the page shows for an update on a press. */
export function describe(update: ActionUpdate, action: Press): string {
  switch (update.kind) {
    case "connect":
      return "Connect a wallet, then press the button again."
    case "switching":
      return "Switching your wallet to Base…"
    case "wallet":
      return `${walletWords(action)} Confirm in your wallet.`
    case "sent":
      return "Sent. Waiting for Base to include it."
    case "done":
      return doneWords(action)
    case "unconfirmed":
      return "Base hasn’t included this yet, and it may still go through. Check your wallet’s activity before pressing again."
    case "failed":
      return refusalWords(update, action)
  }
}

// What the wallet is about to be asked, so the person can check it there.
function walletWords(action: Press): string {
  switch (action.kind) {
    case "vote":
      return `Voting ${action.support ? "yes" : "no"} on proposal ${action.proposal} with ${keyWords(action.keys)}.`
    case "execute":
      return `Carrying out proposal ${action.proposal}.`
    case "propose_decision":
      return `Proposing a decision with key ${action.key}.`
    case "propose_pay":
      return `Proposing ${action.amountWords} to ${shortAddress(action.recipient)}, with key ${action.key}.`
    case "propose_launch":
      return `Proposing a launch that raises ${action.raiseWords}, with key ${action.key}.`
    case "delegate":
      return action.delegate === zeroAddress
        ? "Stopping any other wallet voting for you."
        : `Letting ${shortAddress(action.delegate)} vote and propose with your keys.`
    case "send_share":
      return "Sending the REGENT stakers their share."
  }
}

function doneWords(action: Press): string {
  switch (action.kind) {
    case "vote":
      return `Confirmed. ${capitalized(keyWords(action.keys))} voted ${action.support ? "yes" : "no"}. The count here catches up in a few seconds.`
    case "execute":
      return `Confirmed. Proposal ${action.proposal} has been carried out. This page shows it in a few seconds.`
    case "propose_decision":
    case "propose_pay":
    case "propose_launch":
      return "Confirmed. Your proposal joins the list in a few seconds, and voting on it is open."
    case "delegate":
      return action.delegate === zeroAddress
        ? "Confirmed. No other wallet can vote your keys now."
        : `Confirmed. ${shortAddress(action.delegate)} can now vote and propose with your keys.`
    case "send_share":
      return "Confirmed. The stakers’ share has been sent. The figure here catches up within a minute or so."
  }
}

function refusalWords(refusal: Refusal, action: Press): string {
  switch (refusal.reason) {
    case "no_keys":
      return "Name at least one key to vote with."
    case "unknown_proposal":
      return "Base doesn’t have this proposal yet."
    case "already_executed":
      return "This proposal has already been carried out."
    case "not_passed":
      return "More than half of all the keys sold have to vote yes before this can be carried out."
    case "above_yes_share":
      return "This payment is more than the yes votes’ share of the budget. It can be carried out once more keys vote yes or more money arrives."
    case "launch_exists":
      return "This fleet’s launch is still running or has already succeeded. Another launch can only follow one that didn’t succeed."
    case "zero_asset":
      return "Choose the token to pay."
    case "zero_amount":
      return action.kind === "send_share"
        ? "Nothing is set aside for REGENT stakers right now, so there was nothing to send."
        : "The amount has to be more than zero."
    case "recipient_not_allowed":
      return "The budget can’t pay the fleet itself, its voting or its key holders’ rewards. Choose another wallet to pay."
    case "raise_out_of_bounds":
      return "The REGENT to raise has to be more than zero and no more than an auction can reach."
    case "staking_refused":
      return "REGENT staking didn’t take the share, so it stays set aside. Try again later."
    case "key_not_eligible":
      return action.kind === "vote"
        ? `Key ${refusal.key} can’t vote on this proposal: it was sold or changed hands after the proposal was made, or hasn’t been sold yet.`
        : `Key ${refusal.key} hasn’t been sold yet.`
    case "already_voted":
      return `Key ${refusal.key} already has this vote on this proposal, so none of these votes were counted.`
    case "not_authorized":
      return `Key ${refusal.key} is held by ${shortAddress(refusal.owner)}, who hasn’t let this wallet vote for them.`
    case "launch_not_yet":
      return `A launch can be proposed once ${refusal.required} keys have sold. ${refusal.minted} have sold so far.`
    case "empty_field":
      return `The launch’s ${launchFields[Number(refusal.field)]} can’t be empty.`
    case "field_too_long":
      return `The launch’s ${launchFields[Number(refusal.field)]} is too long: it can be at most ${refusal.maximum} bytes, and this is ${refusal.found}. Plain letters and numbers take one byte each; accented letters take two, and emoji take four.`
    case "wrong_network":
      return "Your wallet is on another network. Switch it to Base and press the button again."
    case "rejected":
      return "You declined in your wallet, so nothing was sent."
    case "unknown":
      return "This didn’t go through. Try again."
  }
}

function number(value: string | undefined): bigint {
  if (!value || !/^[1-9]\d*$/.test(value)) throw new Error("unreadable proposal")
  return BigInt(value)
}

function support(value: string | undefined): boolean {
  if (value === "yes") return true
  if (value === "no") return false
  throw new Error("unreadable support")
}

// Any whole number up to the largest a key number can be is sent as written;
// the contract says which keys exist and which this wallet may use.
function keyList(text: string): bigint[] {
  const entries = text.split(/[\s,]+/).filter(entry => entry !== "")
  if (!entries.every(entry => /^\d+$/.test(entry))) {
    throw new Unreadable("Key numbers are whole numbers, like 3, 7, 12.")
  }
  return entries.map(keyNumber)
}

function proposingKey(text: string): bigint {
  const entry = text.trim()
  if (!/^\d+$/.test(entry)) throw new Unreadable("Name the key you’re proposing with, like 12.")
  return keyNumber(entry)
}

function keyNumber(entry: string): bigint {
  const key = BigInt(entry)
  if (key > maxUint256) throw new Unreadable("That key number is larger than any key number can be.")
  return key
}

// An address in one case, all lower or all upper, carries no checksum; one
// in mixed case has to pass its checksum.
function address(text: string, label: string): Address {
  const entry = text.trim()
  if (!/^0x(?:[0-9a-f]{40}|[0-9A-F]{40})$/.test(entry) && !isAddress(entry)) {
    throw new Unreadable(`${label} isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers.`)
  }
  return getAddress(entry)
}

// The page lists, for each asset it offers, the decimals a whole-token
// amount is converted with and the words that name an amount of it.
function assetOf(listed: string | undefined, asset: Address): {decimals: number; unit: string} {
  if (listed === undefined) throw new Error("unreadable assets")
  const facts: unknown = (JSON.parse(listed) as Record<string, unknown>)[asset.toLowerCase()]
  if (
    typeof facts !== "object" ||
    facts === null ||
    !("decimals" in facts) ||
    !("unit" in facts) ||
    typeof facts.decimals !== "number" ||
    !Number.isInteger(facts.decimals) ||
    facts.decimals < 0 ||
    typeof facts.unit !== "string"
  ) {
    throw new Error("unreadable assets")
  }
  return {decimals: facts.decimals, unit: facts.unit}
}

// A whole-token amount, exactly, in the token's smallest units. Commas may
// only group thousands, and a point marks decimals. Zeros at the end of the
// decimals change nothing; more decimal places than the token has can't be
// paid, so they aren't rounded.
function amount(text: string, decimals: number, largest: bigint): bigint {
  const entry = text.trim()
  if (!/^\d{1,3}(?:,\d{3})+(?:\.\d+)?$/.test(entry) && !/^\d+(?:\.\d+)?$/.test(entry)) {
    throw new Unreadable(
      entry.includes(",")
        ? "Use a point for decimals, like 12.5. Commas can only group thousands, like 1,250."
        : "Write the amount as a number, like 12.5.",
    )
  }
  const [whole, written = ""] = entry.replaceAll(",", "").split(".")
  const fraction = written.replace(/0+$/, "")
  if (fraction.length > decimals) {
    throw new Unreadable(
      decimals === 0 ? "This token is counted in whole units only." : `This token has at most ${decimals} decimal places.`,
    )
  }
  const units = BigInt(whole + fraction.padEnd(decimals, "0"))
  if (units > largest) throw new Unreadable("That amount is too large.")
  return units
}

// An amount in whole tokens, thousands grouped, as the page shows amounts.
function units(amount: bigint, decimals: number): string {
  const [whole, fraction] = formatUnits(amount, decimals).split(".")
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return fraction === undefined ? grouped : `${grouped}.${fraction}`
}

function documentCode(text: string): Hex {
  const entry = text.trim().toLowerCase()
  if (entry === "") return zeroHash
  const match = /^(?:0x)?([0-9a-f]{64})$/.exec(entry)
  if (!match) {
    throw new Unreadable("A document code is 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one.")
  }
  return `0x${match[1]}`
}

function keyWords(keys: bigint[]): string {
  if (keys.length === 0) return "no keys"
  return keys.length === 1 ? `key ${keys[0]}` : `keys ${keys.join(", ")}`
}

function capitalized(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1)
}
