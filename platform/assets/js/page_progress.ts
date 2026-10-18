// A thin bar along the top of the window while the next page is on its way.
// Most pages land before anyone would notice, so the bar waits a moment
// before it shows; when the page lands it fills and fades.

/** How long a page may take before the bar shows, in milliseconds. */
const SHOW_AFTER = 120

type PageLoading = CustomEvent<{kind: string}>

export function installPageProgress(): void {
  const bar = document.createElement("div")
  bar.className = "page-progress"
  bar.setAttribute("aria-hidden", "true")
  document.body.append(bar)
  let timer: number | undefined
  // Back and Forward bring the next page in without a redirect or patch: the
  // page it lands on starts as "initial", like the first page did.
  let landed = false

  window.addEventListener("phx:page-loading-start", event => {
    const {kind} = (event as PageLoading).detail
    if (kind !== "redirect" && kind !== "patch" && !(kind === "initial" && landed)) return
    window.clearTimeout(timer)
    timer = window.setTimeout(() => {
      // Back to empty first, so a bar still fading from the last page starts over.
      delete bar.dataset.state
      void bar.offsetWidth
      bar.dataset.state = "running"
    }, SHOW_AFTER)
  })

  // Any page landing ends the bar, whatever started it: a redirect whose page
  // has to join again only stops when that page's own join does.
  window.addEventListener("phx:page-loading-stop", () => {
    landed = true
    window.clearTimeout(timer)
    if (bar.dataset.state === "running") bar.dataset.state = "done"
  })

  bar.addEventListener("transitionend", event => {
    if (event.propertyName === "opacity" && bar.dataset.state === "done") delete bar.dataset.state
  })
}
