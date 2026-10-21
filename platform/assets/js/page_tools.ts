// The tools a page offers a browser's own agent (WebMCP draft,
// document.modelContext), described in priv/tool_manifest.json.
//
// A page's wallet buttons: a wallet group names its tool with
// `data-webmcp-tool`, and calling it is a press of that group's own button:
// the same steps, built on the server for the signed-in account's wallet, and
// the wallet asks the person to approve. A button the chain's state holds back
// answers why, as the page shows it.
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
// the others press with the form as it is.
const presses: Record<string, (input: Fields) => {step: string; form?: Fields}> = {
  mark_present: () => ({step: "present"}),
  propose: input => ({step: "propose", form: input}),
  run_split: () => ({step: "run_split"}),
  send_share: () => ({step: "send_share"}),
  convert_to_regent: input => ({step: "convert", form: input}),
  vote: input => ({step: input.choice}),
  cancel_proposal: () => ({step: "cancel"}),
  carry_out: () => ({step: "carry_out"}),
  claim: input => ({step: `claim-${input.asset}`}),
}

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

function tool(entry: Entry, root: HTMLElement, pressButton: PressButton): ModelContextTool {
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

      const {step, form} = presses[entry.name](input as Fields)
      const button = buttonFor(root, step)
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
      return answer(await pressButton(button, form ?? {}))
    },
  }
}

/**
 * Offers the tool the wallet group at `root` names, if any, while the group is
 * on the page. Aborting the answer takes it away again.
 */
export function offerPageTool(root: HTMLElement, pressButton: PressButton): AbortController | undefined {
  const entry = entries.find(candidate => candidate.name === root.dataset.webmcpTool && candidate.scope !== "site")
  if (!entry) return undefined

  const registration = new AbortController()
  document.modelContext
    .registerTool(tool(entry, root, pressButton), {signal: registration.signal})
    .catch((error: unknown) => {
      registration.abort()
      console.warn("The browser tool could not be offered.", error)
    })
  return registration
}
