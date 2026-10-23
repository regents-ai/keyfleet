// The tools a page offers a browser's own agent (WebMCP draft,
// document.modelContext), described in priv/tool_manifest.json.
//
// A page's wallet buttons: a wallet group names its tool with
// `data-webmcp-tool` and its fleet with `data-webmcp-fleet`, and calling the
// tool is a press of that group's own button: the same steps, built on the
// server for the signed-in account's wallet, and the wallet asks the person to
// approve. A button the chain's state holds back answers why, as the page
// shows it.
//

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import type {Pressed} from "./hooks/onchain_steps"
import {described} from "./tool_description"
import {inputProblem, type Schema} from "./tool_input"
import type {Failure} from "./wallet_actions/send_step"

type Entry = {
  name: string
  title: string
  description: string
  input_schema: Schema
  annotations: {readOnlyHint: boolean; consequentialHint?: boolean; untrustedContentHint?: boolean}
  scope: string
  requires: string
}

/** A press of one of the group's buttons with the form it reads; "lost" when the page lost its connection. */
export type PressButton = (button: HTMLElement, form: Record<string, string>) => Promise<Pressed | "lost">

type Fields = Record<string, string>

// The button each tool presses, from what the agent sent. Proposing and
// turning USDC into REGENT fill the group's form with what the agent named;
// the others press with the form as it is. Claiming for all your Keys names
// the fleet, since the Account page has a group for each.
const presses: Record<string, (input: Fields) => {step: string; form?: Fields; fleet?: string}> = {
  keys_mark_present: () => ({step: "present"}),
  proposals_create: input => ({step: "propose", form: input}),
  treasury_release: () => ({step: "run_split"}),
  treasury_send_share: () => ({step: "send_share"}),
  treasury_buy_regent: input => ({step: "convert", form: input}),
  proposals_vote: input => ({step: input.choice}),
  proposals_cancel: () => ({step: "cancel"}),
  proposals_carry_out: () => ({step: "carry_out"}),
  keys_claim: input => ({step: `claim-${input.asset}`}),
  keys_claim_all: input => ({step: `claim-${input.asset}`, fleet: input.fleet_id}),
}

type Group = {root: HTMLElement; pressButton: PressButton}

// The tools offered now, each with the wallet groups on the page that name
// it. A tool is offered once while any group names it.
type Offered = {groups: Group[]; registration: AbortController}
const offered = new Map<string, Offered>()

const failures: Record<Failure, {message: string; hint: string}> = {
  step_unknown: {
    message: "This can't be sent as it stands. Nothing was sent.",
    hint: "Check the details on the page, then call again.",
  },
  wallet_unavailable: {
    message: "No wallet on the signed-in account is open, so nothing was sent.",
    hint: "Sign in, open a wallet on your account in the wallet app, then call again.",
  },
  network_mismatch: {
    message: "The wallet didn't switch to the page's network. Nothing was sent.",
    hint: "Switch the wallet to the network the page names, adding it if the wallet doesn't list it, then call again.",
  },
  wallet_declined: {
    message: "The wallet declined this. Nothing was sent.",
    hint: "Ask the person signed in before calling again.",
  },
  insufficient_funds: {
    message: "The wallet can't pay the network fee. Nothing was sent.",
    hint: "Add funds for the network fee to the wallet, then call again.",
  },
  send_unconfirmed: {
    message: "The wallet may have sent this.",
    hint: "Check the wallet's activity before calling again.",
  },
}

// JSON imports widen every literal, so the manifest is read as the shape it is written in.
const entries = manifest.tools as unknown as Entry[]

function refusal(code: string, message: string, hint: string) {
  return {ok: false, error: {code, message, hint}}
}

function answer(pressed: Pressed | "lost") {
  if (pressed === "lost") {
    return refusal(
      "connection_lost",
      "This page lost its connection, so nothing was sent.",
      "Call again once the page is back.",
    )
  }
  if ("transaction_hash" in pressed) {
    return {ok: true, transaction_hash: pressed.transaction_hash, note: "Sent from the wallet. The page shows when it lands."}
  }
  if ("signature" in pressed) return {ok: true, signature: pressed.signature}
  const {message, hint} = failures[pressed.reason]
  return refusal(pressed.reason, message, hint)
}

// Addresses in a step's name may be written in either case.
function buttonFor(root: HTMLElement, step: string): HTMLButtonElement | undefined {
  const name = step.toLowerCase()
  return [...root.querySelectorAll<HTMLButtonElement>("button[data-onchain-step]")].find(
    button => button.dataset.onchainStep?.toLowerCase() === name,
  )
}

function tool(entry: Entry, held: Offered): ModelContextTool {
  return {
    name: entry.name,
    title: entry.title,
    description: described(entry),
    inputSchema: entry.input_schema,
    annotations: entry.annotations,
    async execute(input: unknown, {signal}: {signal?: AbortSignal}) {
      const problem = inputProblem(input, entry.input_schema)
      if (problem) return refusal("invalid_input", problem, "Fix the call, then call again.")
      if (signal?.aborted) return refusal("cancelled", "The call was cancelled; nothing was sent.", "Call again to send it.")

      const {step, form, fleet} = presses[entry.name](input as Fields)
      const group = held.groups.find(({root}) => fleet === undefined || root.dataset.webmcpFleet === fleet)
      const button = group && buttonFor(group.root, step)
      if (!button) {
        return refusal(
          "not_on_page",
          `This page shows no ${entry.title} button for that now.`,
          "Sign in, and check what the page offers, then call again.",
        )
      }
      // A held-back button names, beside it, why the chain's state makes it certain to fail.
      if (button.disabled) {
        const why = document.getElementById(button.getAttribute("aria-describedby")!)!
        return refusal("blocked", why.textContent!.trim(), "It comes back when that changes on the chain.")
      }
      return answer(await group.pressButton(button, form ?? {}))
    },
  }
}

/**
 * Offers the tool the wallet group at `root` names, if any, while the group is
 * on the page. Aborting the answer takes the group away again, and the tool
 * once no group on the page names it.
 */
export function offerPageTool(root: HTMLElement, pressButton: PressButton): AbortController | undefined {
  const entry = entries.find(candidate => candidate.name === root.dataset.webmcpTool && candidate.scope !== "site")
  if (!entry) return undefined

  const group = {root, pressButton}
  const held = offered.get(entry.name) ?? offer(entry)
  held.groups.push(group)

  const leaving = new AbortController()
  leaving.signal.addEventListener("abort", () => {
    held.groups = held.groups.filter(other => other !== group)
    if (held.groups.length === 0) held.registration.abort()
  })
  return leaving
}

function offer(entry: Entry): Offered {
  const held: Offered = {groups: [], registration: new AbortController()}
  offered.set(entry.name, held)
  held.registration.signal.addEventListener("abort", () => {
    if (offered.get(entry.name) === held) offered.delete(entry.name)
  })
  document.modelContext
    .registerTool(tool(entry, held), {signal: held.registration.signal})
    .catch((error: unknown) => {
      held.registration.abort()
      console.warn("The browser tool could not be offered.", error)
    })
  return held
}
