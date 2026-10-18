// Offers the site's public browser tools (public_tool_list.ts) to a browser
// that has its own agent (document.modelContext). Every other browser never
// downloads them.

// One registration per shown page: register on pageshow, remove on pagehide,
// so a page restored from the back/forward cache never holds two sets. The
// html element's data-webmcp-status says whether the browser holds them all;
// only the latest registration writes it.
export function installPublicTools(): void {
  const status = document.documentElement.dataset
  if (!("modelContext" in document)) {
    status.webmcpStatus = "unsupported"
    return
  }
  let registration: AbortController | undefined

  window.addEventListener("pageshow", () => {
    const current = new AbortController()
    registration = current
    const {signal} = current
    import("./public_tool_list")
      .then(({tools}) => {
        // The page was hidden while the tools were on their way.
        if (signal.aborted) return
        return Promise.all(tools.map(tool => document.modelContext.registerTool(tool, {signal})))
          .then(() => document.modelContext.getTools())
          .then(held => {
            if (registration !== current) return
            const names = new Set(held.map(tool => tool.name))
            status.webmcpStatus = tools.every(tool => names.has(tool.name)) ? "connected" : "error"
          })
      })
      .catch((error: unknown) => {
        current.abort()
        if (registration !== current) return
        status.webmcpStatus = "error"
        console.warn("The browser tools could not be offered.", error)
      })
  })
  window.addEventListener("pagehide", () => registration?.abort())
}
