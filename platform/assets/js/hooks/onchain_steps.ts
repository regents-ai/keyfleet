import type {Address, Hash, Hex} from "viem"

import type {Hook} from "../hook_composition"
import type {PressButton} from "../page_tools"
import {activeEthereumWallet} from "../wallet_actions/connected_wallet"
import {
  failure,
  NothingSent,
  sendStep,
  signStep,
  type Failure,
  type Step,
  type StepChain,
} from "../wallet_actions/send_step"

/**
 * Who sends, on which chain, the steps the buttons name, and the on-screen
 * inputs they were built from, all on the server. It never changes: a new
 * figure is a new review with a new id.
 */
export type Review = {
  id: string
  component_id: string
  signer: Address
  chain: StepChain
  steps: Step[]
  inputs: Record<string, string>
}

/** What the wallet answered one press: the hash or signature, or why nothing was sent. */
export type Pressed = {transaction_hash: Hash} | {signature: Hex} | {reason: Failure}

type Push = (event: string, payload: unknown) => void

type OnchainStepsHook = Hook & {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload?: unknown): Promise<PromiseSettledResult<{reply: unknown}>[]>
  review?: Review
  clicked?: (event: Event) => void
  pressButton?: PressButton
  tool?: Promise<AbortController | undefined>
  refresh?: () => void
  walletChanged?: () => void
}

// How many of a button's presses the wallet still has. The mark comes off when
// the last one is answered.
const presses = new WeakMap<HTMLElement, number>()

/**
 * The wallet buttons of one server component. The component's root carries the
 * hook and a DOM id; each button names its step with `data-onchain-step`, and
 * each form field the review depends on is marked `data-onchain-input="name"`.
 * A root marked `data-refresh-funds` also asks the server to read its funds
 * again (`refresh_funds`) when the wallet changes, when the page comes back
 * into view, when the panel holding it opens (`ash:refresh-funds` on the root)
 * and after each press.
 */
export const OnchainSteps: Hook = {
  mounted(this: OnchainStepsHook) {
    const push: Push = (event, payload) => void this.pushEventTo(this.el, event, payload)

    // Every hook on the page hears this event; keep only this component's review.
    // No review means none is built yet, or no wallet may send.
    this.handleEvent("onchain-steps:review", payload => {
      const {component_id, review} = payload as {component_id: string; review: Review | null}
      if (component_id === this.el.id) this.review = review ?? undefined
    })

    // Every press runs on its own and reaches the wallet, even while an earlier
    // one is still there. A press whose step isn't on the page yet, or whose
    // review no longer matches the form, asks the server for the matching
    // review and sends what comes back. The browser's own agent presses the
    // same way, through the tool the group names (page_tools.ts).
    this.pressButton = async (button, form) => {
      const name = button.dataset.onchainStep!
      const release = mark(button)
      const asks = asksServer(this.review, name, form)
      lost(this.el, false)
      // The server hears the press, and the form it was made from, just before
      // the wallet does and once its steps are built from that form: a
      // proposal's words are saved then. The press never waits on this.
      const heard = () => push("step_pressed", {step: name, form})

      try {
        if (!(activeEthereumWallet() && asks)) {
          heard()
          return await press(this.review, name, push)
        }
        const [result] = await this.pushEventTo(this.el, "prepare_and_send", {form, step: name})
        // The server never heard the press, so it cannot say why; the page does.
        if (result?.status !== "fulfilled") return lostPress(this.el)
        const reply = result.value.reply as {review?: Review; send?: string}
        if (reply.review && reply.send) {
          heard()
          return await press(reply.review, reply.send, push)
        }
        push("step_failed", {step: name, reason: "step_unknown"})
        return {reason: "step_unknown"}
      } catch {
        return lostPress(this.el)
      } finally {
        release()
        // The press may have spent funds or changed what the wallet allows.
        this.refresh?.()
      }
    }

    // Signed out, a button carries the page's sign-in mark, and its press
    // opens sign-in instead (auth_lazy.ts).
    this.clicked = event => {
      const button = (event.target as Element | null)?.closest<HTMLElement>("[data-onchain-step]")
      if (!button?.dataset.onchainStep || !this.el.contains(button)) return
      if (button.dataset.accountTarget === "sign-in") return
      void this.pressButton!(button, formInputs(this.el))
    }
    this.el.addEventListener("click", this.clicked)

    // The server decides which wallet may act; it hears every change of the
    // wallet Privy has active and pushes a new review, or none.
    this.walletChanged = () => push("onchain_active_wallet", {address: activeEthereumWallet()?.address ?? null})
    window.addEventListener("ash:wallet-state", this.walletChanged)
    this.walletChanged()

    if (this.el.hasAttribute("data-refresh-funds")) {
      this.refresh = () => push("refresh_funds", {})
      window.addEventListener("ash:wallet-state", this.refresh)
      window.addEventListener("focus", this.refresh)
      this.el.addEventListener("ash:refresh-funds", this.refresh)
      this.refresh()
    }
    window.dispatchEvent(new CustomEvent("ash:wallet-sync"))

    // Only a browser with its own agent loads the tools.
    if ("modelContext" in document) {
      this.tool = import("../page_tools").then(({offerPageTool}) =>
        offerPageTool(this.el, (button, form) => this.pressButton!(button, {...formInputs(this.el), ...form})),
      )
    }
  },

  destroyed(this: OnchainStepsHook) {
    void this.tool?.then(registration => registration?.abort())
    if (this.clicked) this.el.removeEventListener("click", this.clicked)
    if (this.walletChanged) window.removeEventListener("ash:wallet-state", this.walletChanged)
    if (this.refresh) {
      window.removeEventListener("ash:wallet-state", this.refresh)
      window.removeEventListener("focus", this.refresh)
      this.el.removeEventListener("ash:refresh-funds", this.refresh)
    }
  },
}

/**
 * Sends or signs the named step from Privy's active wallet, the only wallet that
 * acts, when it is the signer the server built the review for. With no wallet
 * active, the press sends nothing and the server's note says why. Reports only
 * what the wallet answered, against the review it sent from: the hash or
 * signature, or why nothing was sent, and returns the same answer. The server
 * decides what the hash did.
 */
export async function press(review: Review | undefined, name: string, push: Push): Promise<Pressed> {
  const step = review?.steps.find(candidate => candidate.step === name)
  let sending = false
  const started = () => {
    sending = true
  }

  try {
    if (!activeEthereumWallet()) throw new NothingSent("wallet_unavailable")
    if (!review || !step) throw new NothingSent("step_unknown")
    const wallet = () => {
      const active = activeEthereumWallet()
      return active?.address.toLowerCase() === review.signer.toLowerCase() ? active : null
    }
    if (!wallet()) throw new NothingSent("wallet_unavailable")

    if (step.kind === "signature") {
      const signature = await signStep(review.chain, review.signer, step, wallet, started)
      push("step_signed", {review_id: review.id, step: name, signature})
      return {signature}
    }
    const transaction_hash = await sendStep(review.chain, review.signer, step, wallet, started)
    push("step_sent", {review_id: review.id, step: name, transaction_hash})
    return {transaction_hash}
  } catch (error) {
    const reason = failure(sending, error)
    push("step_failed", {step: name, reason})
    return {reason}
  }
}

/**
 * The review's inputs as they are on screen now: text as typed, a box as
 * "true" or "false", and a group of choices as the one chosen.
 */
export function formInputs(root: HTMLElement): Record<string, string> {
  const inputs: Record<string, string> = {}
  root.querySelectorAll<HTMLInputElement | HTMLSelectElement>("[data-onchain-input]").forEach(input => {
    const name = input.dataset.onchainInput
    if (!name) return
    if (input instanceof HTMLInputElement && input.type === "radio") {
      if (input.checked) inputs[name] = input.value
    } else {
      inputs[name] = input instanceof HTMLInputElement && input.type === "checkbox" ? String(input.checked) : input.value
    }
  })
  return inputs
}

/**
 * Whether a press must ask the server for its review first: its step isn't in
 * the review on the page (none has arrived yet, as when the button has just
 * appeared), or the review was built from other inputs than the form shows.
 */
export function asksServer(review: Review | undefined, name: string, form: Record<string, string>): boolean {
  if (!review?.steps.some(step => step.step === name)) return true
  return Object.keys(form).length > 0 && !sameInputs(review.inputs, form)
}

function sameInputs(review: Record<string, string>, form: Record<string, string>): boolean {
  const names = new Set([...Object.keys(review), ...Object.keys(form)])
  return [...names].every(name => review[name] === form[name])
}

// The component's `data-onchain-lost` line, shown when a press could not reach
// the server. The next render from the server hides it again.
function lost(root: HTMLElement, shown: boolean): void {
  const line = root.querySelector<HTMLElement>("[data-onchain-lost]")
  if (line) line.hidden = !shown
}

// A press that could not reach the server: the page says so, and so does the answer.
function lostPress(root: HTMLElement): "lost" {
  lost(root, true)
  return "lost"
}

// Marked with a data attribute and CSS only: the button keeps taking presses.
function mark(button: HTMLElement): () => void {
  presses.set(button, (presses.get(button) ?? 0) + 1)
  button.dataset.awaitingWallet = "true"

  return () => {
    const left = (presses.get(button) ?? 1) - 1
    presses.set(button, left)
    if (left <= 0) delete button.dataset.awaitingWallet
  }
}
