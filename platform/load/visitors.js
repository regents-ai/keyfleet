// Signed-out visitors of Keyfleet, as k6 virtual users: each one opens a page,
// keeps it open as a reader would, leaves, and comes back as a new visitor.
// One VU is one open page, so the VU count is the count of open pages.
//
//   platform/load/local.sh ramp     # starts the release on this computer and runs this
//
// platform/load/README.md lists every scenario, setting and pass mark. The
// script loads only http://127.0.0.1 or localhost, and refuses keyfleet.ai
// and the production app's other addresses by name too, before it sends
// anything (lib/config.js).

import { buildOptions, settings, site } from "./lib/config.js"
import { discoverPages, pickPage } from "./lib/paths.js"
import { visit } from "./lib/live.js"

export const options = buildOptions()

export function setup() {
  return { pages: discoverPages(site, settings.pollPath) }
}

export default function (data) {
  const dwell = settings.dwellMin + Math.random() * (settings.dwellMax - settings.dwellMin)
  visit(pickPage(data.pages), Date.now() + dwell * 1000)
}
