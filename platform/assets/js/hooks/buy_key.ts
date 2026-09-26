import type {Hook} from "../hook_composition"
import {deny} from "./motion/press"
import {activeEthereumWallet, type SelectedWallet} from "../wallet_actions/connected_wallet"
import {
  buyKey,
  describe,
  outOfDateWords,
  readKeyOrder,
  type BuyUpdate,
  type KeyOrder,
} from "../wallet_actions/buy_key"
import {onWalletChange, showWalletNote} from "../wallet_actions/signed_in"

type BuyKeyHook = Hook & {
  el: HTMLElement
  cleanup?: () => void
}

type Purchase = (
  order: KeyOrder,
  wallet: SelectedWallet,
  report: (update: BuyUpdate) => void,
) => Promise<void>

// Only the latest few presses stay listed.
const shownPresses = 5

/**
 * The fleet page's Buy button. Every press is its own purchase: nothing here
 * disables the button, waits for an earlier press, or decides for the buyer
 * whether the purchase would succeed. The wallet and the contract answer that.
 * When the connected wallet isn't the signed-in person's, a note says so, and
 * the press still goes to the connected wallet.
 */
export function buyKeyHook(
  currentWallet: () => SelectedWallet | null = activeEthereumWallet,
  purchase: Purchase = buyKey,
): Hook {
  return {
    mounted(this: BuyKeyHook) {
      const root = this.el
      const note = () => showWalletNote(root, currentWallet())

      const press = (event: Event) => {
        if (!(event.target as Element | null)?.closest("[data-buy-key]")) return
        const entry = statusEntry(root)
        let order: KeyOrder
        try {
          order = readKeyOrder(root.dataset)
        } catch {
          entry.textContent = outOfDateWords
          entry.dataset.tone = "error"
          deny(entry)
          return
        }
        const show = (update: BuyUpdate) => {
          entry.textContent = describe(update, order)
          entry.dataset.tone = update.kind === "failed" ? "error" : "info"
          if (update.kind === "failed") deny(entry)
        }

        const wallet = currentWallet()
        if (!wallet) {
          show({kind: "connect"})
          window.dispatchEvent(new Event("ash:wallet-connect"))
          return
        }

        void purchase(order, wallet, show)
      }

      note()
      const stopWatching = onWalletChange(note)
      root.addEventListener("click", press)
      this.cleanup = () => {
        stopWatching()
        root.removeEventListener("click", press)
      }
    },

    updated(this: BuyKeyHook) {
      showWalletNote(this.el, currentWallet())
    },

    destroyed(this: BuyKeyHook) {
      this.cleanup?.()
    },
  }
}

export const BuyKey: Hook = buyKeyHook()

function statusEntry(root: HTMLElement): HTMLElement {
  const list = root.querySelector<HTMLElement>("#buy-key-status")!
  const entry = root.ownerDocument.createElement("li")
  list.prepend(entry)
  while (list.children.length > shownPresses) list.lastElementChild!.remove()
  return entry
}
