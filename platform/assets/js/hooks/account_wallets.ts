import type {Hook} from "../hook_composition"
import {activeEthereumWallet, regentsWallets} from "../wallet_actions/connected_wallet"

interface AccountWalletsHook {
  el: HTMLElement
  report?: () => void
  pushEventTo(target: HTMLElement, event: string, payload: object): void
}

// The person's wallets (`KeyfleetWeb.AccountWallets`) learn from this browser
// which wallet is active and which one Privy made at sign-in: when the page
// arrives and each time the wallet changes.
export const AccountWallets: Hook = {
  mounted(this: AccountWalletsHook) {
    this.report = () =>
      this.pushEventTo(this.el, "wallets_seen", {
        active: activeEthereumWallet()?.address ?? null,
        regents: regentsWallets(),
      })
    window.addEventListener("ash:wallet-state", this.report)
    this.report()
  },

  destroyed(this: AccountWalletsHook) {
    if (this.report) window.removeEventListener("ash:wallet-state", this.report)
  },
}
