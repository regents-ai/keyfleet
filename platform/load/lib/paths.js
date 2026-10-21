// The pages a signed-out visitor opens, and how often. Every address comes
// from platform/lib/keyfleet_web/router.ex and KeyfleetWeb.RouteCatalog: the
// fleets' own addresses are in Keyfleet.Fleets' catalog, and a fleet's rooms
// are under its address. Nothing here needs a wallet or sign-in: the Public
// room is the one room anyone reads (Keyfleet.Access, :general_room).

import http from "k6/http"

const CLUB = "/app/fleets/regents_club"

// Most visitors land on the homepage; the rest arrive on a fleet's page from a
// link someone shared. The weights add up to 100.
const MIX = [
  { name: "home", path: "/", weight: 50 },
  // Classic #1 is still coming soon: its name, its faded map and its terms.
  { name: "classic", path: "/classic/1", weight: 10 },
  // The Regents Club's hall, the fleet page's first view (KeyLinks.hall_path/1).
  { name: "club_hall", path: CLUB, weight: 15 },
  // The Club's page of Keys, its map (KeyLinks.map_path/1).
  { name: "club_keys", path: `${CLUB}?view=map`, weight: 10 },
  { name: "club_room", path: `${CLUB}/rooms/general`, weight: 15 },
]

function get(base, path) {
  return http.get(base + path, { tags: { kind: "setup", name: "setup" } })
}

// Checks every page answers as a visitor would see it, so a run against a
// site missing what it needs stops before the load starts and says what to
// fix.
export function discoverPages(site) {
  const pages = MIX.map((page) => Object.assign({}, page))

  for (const page of pages) {
    const res = get(site.base, page.path)
    if (res.status !== 200) throw new Error(`${page.path} answered ${res.status}; every visitor page must answer 200 before a run`)
    if (!/data-phx-main/.test(String(res.body))) throw new Error(`${page.path} drew no live page`)
    if (page.name === "club_hall" && /id="fleet-soon-title"/.test(String(res.body))) {
      throw new Error(
        "The Regents Club shows as coming soon here, so it has no rooms: its deployment was not recorded (local.sh records KEYFLEET_DEPLOYED_RECORD with /app/bin/seed-deployment)",
      )
    }
  }
  return pages
}

export function pickPage(pages) {
  let roll = Math.random() * 100
  for (const page of pages) {
    roll -= page.weight
    if (roll < 0) return page
  }
  return pages[0]
}
