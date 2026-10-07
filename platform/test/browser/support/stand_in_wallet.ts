import type {Page} from "@playwright/test"

import type {SentTransaction} from "./fleet_chain"

/** What the stand-in wallet does with a transaction it is asked to send. */
export type Answer = "send" | "decline"

type StandIn = {sent: SentTransaction[]; hashes: string[]; answer: Answer}

declare global {
  interface Window {
    standInWallet?: StandIn
  }
}

/**
 * Makes a stand-in wallet on Base, holding `address`, Privy's active wallet
 * in the open page, as Privy does once a person picks a wallet. It sends
 * nothing anywhere: each transaction it is asked to send is kept, answered
 * with a new random hash, or declined as a person declining in their wallet
 * app would. The page's scripts are ES modules, so the one that keeps the
 * active wallet is found among those the page's script imports, and is the
 * same module the page's buttons read.
 */
export async function useStandInWallet(page: Page, address: string, answer: Answer = "send") {
  await page.evaluate(
    async ({address, answer}) => {
      const script = document.querySelector<HTMLScriptElement>('script[type=module][src*="/assets/js/app"]')!.src
      const source = await (await fetch(script)).text()
      const chunks = [...source.matchAll(/from "(\.\/chunk-[A-Z0-9]+\.js)"/g)].map(match => new URL(match[1], script).href)

      for (const chunk of chunks) {
        const module = await import(chunk)
        if (typeof module.replaceActiveEthereumWallet !== "function") continue

        const standIn: StandIn = window.standInWallet ?? {sent: [], hashes: [], answer}
        standIn.answer = answer
        window.standInWallet = standIn

        const provider = {
          async request({method, params}: {method: string; params?: unknown[]}) {
            switch (method) {
              case "eth_chainId":
                return "0x2105"
              case "eth_accounts":
                return [address]
              case "eth_sendTransaction": {
                if (standIn.answer === "decline") {
                  throw Object.assign(new Error("User rejected the request."), {code: 4001})
                }
                const sent = (params as SentTransaction[])[0]
                // Every hash is new, as a real chain's are, across pages and runs.
                const bytes = crypto.getRandomValues(new Uint8Array(32))
                const hash = `0x${[...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("")}`
                standIn.sent.push(sent)
                standIn.hashes.push(hash)
                return hash
              }
              default:
                throw Object.assign(new Error(`The stand-in wallet does not answer ${method}.`), {code: 4200})
            }
          },
        }

        module.replaceActiveEthereumWallet({address, provider})
        window.dispatchEvent(new CustomEvent("ash:wallet-state"))
        return
      }

      throw new Error("No page module keeps the active wallet.")
    },
    {address, answer},
  )
}

/** Every transaction the stand-in wallet was asked to send and sent, with its hash, oldest first. */
export async function sentByStandIn(page: Page): Promise<{hash: string; transaction: SentTransaction}[]> {
  return page.evaluate(() => {
    const standIn = window.standInWallet
    return standIn ? standIn.sent.map((transaction, index) => ({hash: standIn.hashes[index], transaction})) : []
  })
}
