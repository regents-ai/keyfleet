import {afterEach, expect, it, vi} from "vitest"

import {
  browserCsrfToken,
  holdAdoptionWhileLeaving,
  holdSocketDuringCookieRotation,
} from "../js/auth_lazy"
import {createLocalSession} from "../js/privy_bridge"

// Its own file: once a document starts leaving it never stops, so the module
// state this case leaves behind must not reach the barrier's other cases.

afterEach(() => vi.unstubAllGlobals())

// The pinned phoenix 1.8.9 socket's establishment surface, as in
// session_authority_browser.test.ts.
function pinnedSocket() {
  const attempts: string[] = []
  let live = false
  const socket = {
    attempts,
    connect: () => {
      if (live) return
      socket.transportConnect()
    },
    transportConnect: () => {
      live = true
      attempts.push(browserCsrfToken())
    },
  }

  return socket
}

it("asks for no session once the document reloading after a refused bearer has begun to leave", async () => {
  vi.stubGlobal("document", {
    querySelector: (selector: string) =>
      selector === "meta[name='csrf-token']" ? {content: "page-token"} : null,
  })
  const view = new EventTarget()
  const socket = pinnedSocket()
  const requests: string[] = []
  const fetcher = vi.fn(async (input: RequestInfo | URL) => {
    requests.push(String(input))
    return input === "/auth/csrf"
      ? new Response(JSON.stringify({csrf_token: "before-post"}), {status: 200})
      : new Response("{}", {status: 401})
  }) as unknown as typeof fetch
  holdSocketDuringCookieRotation(socket, fetcher)
  holdAdoptionWhileLeaving(view as unknown as Window)

  // The 401 dropped this browser's cookie, and the page reloads at once.
  await expect(
    createLocalSession({accessToken: "refused", identityToken: "refused-identity"}, fetcher),
  ).rejects.toThrow()
  view.dispatchEvent(new Event("beforeunload"))

  // Only then does the server's disconnect reach this page's socket, and its
  // reconnect stays held instead of writing a cookie behind the new page.
  socket.connect()
  await new Promise(resolve => setTimeout(resolve, 0))

  expect(requests).toEqual(["/auth/csrf", "/auth/privy/session"])
  expect(socket.attempts).toEqual([])
})
