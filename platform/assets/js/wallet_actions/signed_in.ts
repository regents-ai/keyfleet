import type {SelectedWallet} from "./connected_wallet"

/**
 * The note beside the wallet buttons when the connected wallet isn't one of
 * the signed-in person's. It only informs: every press still goes to the
 * connected wallet.
 */

/** What the note says when the page's list of signed-in wallets can't be read. */
export const unreadableSignedInWords = "This page is out of date. Refresh it to see which wallet you’re signed in with."

/** The signed-in person's wallets from the page's `data-signed-in`, lower-cased, primary first. */
export function readSignedIn(listed: string | undefined): string[] {
  if (listed === undefined) throw new Error("unreadable signed-in wallets")
  const wallets: unknown = JSON.parse(listed)
  if (!Array.isArray(wallets) || !wallets.every(wallet => typeof wallet === "string" && /^0x[0-9a-f]{40}$/.test(wallet))) {
    throw new Error("unreadable signed-in wallets")
  }
  return wallets
}

/** The note's words when the connected wallet isn't one of the signed-in person's, or null. */
export function mismatchWords(signedIn: readonly string[], wallet: SelectedWallet | null): string | null {
  if (signedIn.length === 0 || wallet === null) return null
  const connected = wallet.address.toLowerCase()
  if (signedIn.includes(connected)) return null
  return `You’re signed in as ${shortAddress(signedIn[0])} but your wallet is on ${shortAddress(connected)}. Presses here go to ${shortAddress(connected)}.`
}

/** Writes the note inside `root` for the wallet connected now. */
export function showWalletNote(root: HTMLElement, wallet: SelectedWallet | null): void {
  const note = root.querySelector<HTMLElement>("[data-wallet-note]")!
  let signedIn: string[]
  try {
    signedIn = readSignedIn(root.dataset.signedIn)
  } catch {
    note.textContent = unreadableSignedInWords
    return
  }
  note.textContent = mismatchWords(signedIn, wallet)
}

/** Calls `changed` whenever the page's connected wallet changes, until the returned stop is called. */
export function onWalletChange(changed: () => void): () => void {
  window.addEventListener("ash:wallet-state", changed)
  return () => window.removeEventListener("ash:wallet-state", changed)
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}
