import type {Hook} from "../hook_composition"
import {activeEthereumWallet, type SelectedWallet} from "../wallet_actions/connected_wallet"
import {
  describe,
  outOfDateWords,
  readAction,
  readTarget,
  runAction,
  Unreadable,
  type ActionUpdate,
  type Press,
  type Target,
} from "../wallet_actions/fleet_action"
import {onWalletChange, showWalletNote} from "../wallet_actions/signed_in"

type FleetActionHook = Hook & {
  el: HTMLElement
  cleanup?: () => void
}

type Run = (
  target: Target,
  action: Press,
  wallet: SelectedWallet,
  report: (update: ActionUpdate) => void,
) => Promise<void>

// Only the latest few presses stay listed.
const shownPresses = 5

/**
 * The proposal pages' wallet buttons: vote, carry out, propose, let another
 * wallet vote, and send the stakers their share. Every press is its own call:
 * nothing here disables a button, waits for an earlier press, or decides
 * whether the contract will take it, whatever the page shows. The wallet and
 * the contract answer that, and the answer is shown beside the button. When
 * the connected wallet isn't the signed-in person's, a note says so, and the
 * press still goes to the connected wallet.
 */
export function fleetActionHook(
  currentWallet: () => SelectedWallet | null = activeEthereumWallet,
  run: Run = runAction,
): Hook {
  return {
    mounted(this: FleetActionHook) {
      const root = this.el
      const note = () => showWalletNote(root, currentWallet())

      const press = (event: Event) => {
        const button = (event.target as Element | null)?.closest<HTMLElement>("[data-fleet-action]")
        if (!button) return
        const entry = statusEntry(root)

        let target: Target
        let action: Press
        try {
          target = readTarget(root.dataset)
          action = readAction(button.dataset.fleetAction, {...root.dataset, ...button.dataset}, name => field(root, name))
        } catch (error) {
          entry.textContent = error instanceof Unreadable ? error.message : outOfDateWords
          entry.dataset.tone = "error"
          return
        }

        const show = (update: ActionUpdate) => {
          entry.textContent = describe(update, action)
          entry.dataset.tone = update.kind === "failed" ? "error" : "info"
        }

        const wallet = currentWallet()
        if (!wallet) {
          show({kind: "connect"})
          window.dispatchEvent(new Event("ash:wallet-connect"))
          return
        }

        void run(target, action, wallet, show)
      }

      note()
      const stopWatching = onWalletChange(note)
      root.addEventListener("click", press)
      this.cleanup = () => {
        stopWatching()
        root.removeEventListener("click", press)
      }
    },

    updated(this: FleetActionHook) {
      showWalletNote(this.el, currentWallet())
    },

    destroyed(this: FleetActionHook) {
      this.cleanup?.()
    },
  }
}

export const FleetAction: Hook = fleetActionHook()

// What the person entered in the page's form field `name`, as written.
function field(root: HTMLElement, name: string): string {
  return root.querySelector<HTMLInputElement>(`[name="${name}"]`)!.value
}

function statusEntry(root: HTMLElement): HTMLElement {
  const list = root.querySelector<HTMLElement>("[data-fleet-action-status]")!
  const entry = root.ownerDocument.createElement("li")
  list.prepend(entry)
  while (list.children.length > shownPresses) list.lastElementChild!.remove()
  return entry
}
