// The steps a visitor takes into Keyfleet, each sent to this site once as it
// happens and counted there with nothing saved (KeyfleetWeb.LaunchSteps): the
// homepage opened, "Watch a live fleet" or "Connect my agent" pressed, and a
// setup line copied, with the agent it is for. A report names only the step
// and that agent: no person, address, wallet or Key.

type Report = {step: "home" | "watch" | "connect"} | {step: "copy"; agent: string}

export function installLaunchSteps(): void {
  // A browser a program drives, such as a test, a Lighthouse run or a crawler,
  // is not a visitor, so it reports nothing.
  if (navigator.webdriver || typeof navigator.sendBeacon !== "function") return

  const send = (report: Report) => navigator.sendBeacon("/steps", JSON.stringify(report))

  // Each arrival at the homepage, by loading it or by a link from another
  // page. A page that reconnects or redraws in place is not a new arrival.
  let shown: string | undefined
  window.addEventListener("phx:page-loading-stop", () => {
    const path = window.location.pathname
    if (path === "/" && shown !== "/") send({step: "home"})
    shown = path
  })

  // Captured before LiveView takes the press over for its own navigation.
  document.addEventListener(
    "click",
    event => {
      const link = event.target instanceof Element ? event.target.closest<HTMLElement>("[data-step]") : null
      const step = link?.dataset.step
      if (step === "watch" || step === "connect") send({step})
    },
    true,
  )

  // Only a copy that worked, as the copy buttons report it.
  document.addEventListener("copy-button:copied", event => {
    const agent = event.target instanceof HTMLElement ? event.target.dataset.stepAgent : undefined
    if (agent) send({step: "copy", agent})
  })
}
