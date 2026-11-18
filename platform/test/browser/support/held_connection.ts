import type {Page} from "@playwright/test"

/**
 * The page's live connection, relayed so a walk can hold back what the server
 * sends, as a slow network would. Install it before the page opens.
 *
 * `hold("recovery")` holds the server's answer to the forms LiveView sends back
 * when the page joins again, which it waits for before it draws the page and
 * runs the hooks' `reconnected`; `hold("ask")` holds the answer to the next
 * press that asks the server for its steps (`prepare_and_send`). Either way
 * everything the server sends after it is held too, and `release` sends it all
 * on, in order. `asks` counts the asks the page has sent; `unanswered` counts
 * the messages the page has sent on its open connection whose answer it has not
 * been given yet.
 */
export async function holdConnection(page: Page) {
  let armed: "recovery" | "ask" | null = null
  let asks = 0
  let held: (() => void)[] | null = null
  const watched = new Set<string>()
  const unanswered = new Set<string>()

  await page.routeWebSocket(/\/live\/websocket/, socket => {
    // A connection dropped takes its unanswered messages with it.
    unanswered.clear()
    const server = socket.connectToServer()
    socket.onMessage(message => {
      if (typeof message === "string") {
        const [, ref, , kind, payload] = JSON.parse(message)
        if (ref) unanswered.add(ref)
        const ask = kind === "event" && payload?.event === "prepare_and_send"
        if (ask) asks += 1
        if ((armed === "recovery" && kind === "event" && payload?.type === "form") || (armed === "ask" && ask)) watched.add(ref)
      }
      server.send(message)
    })
    server.onMessage(message => {
      const deliver = () => {
        if (typeof message === "string") {
          const [, ref, , kind] = JSON.parse(message)
          if (kind === "phx_reply") unanswered.delete(ref)
        }
        socket.send(message)
      }
      if (!held && typeof message === "string") {
        const [, ref, , kind] = JSON.parse(message)
        if (kind === "phx_reply" && watched.has(ref)) held = []
      }
      if (held) held.push(deliver)
      else deliver()
    })
  })

  return {
    hold: (what: "recovery" | "ask") => {
      armed = what
    },
    holding: () => held !== null,
    asks: () => asks,
    unanswered: () => unanswered.size,
    release: () => {
      const waiting = held ?? []
      held = null
      armed = null
      watched.clear()
      for (const send of waiting) send()
    },
  }
}
