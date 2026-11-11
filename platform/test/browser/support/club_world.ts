import {furnishFleet, prepareFleet} from "./fleet_chain"

// The site as a first-time visitor finds it at launch: the Regents Club open,
// with a post in the Public room, a goal, a task and a proposal, and Classic #1
// still coming soon. playwright.devices.config.ts runs this once, after its
// server has started and before any spec, so every device sees the same site.
// The specs find what is here through the pages' own links, so they run as
// they are against a real site that holds these things too.
const clubHolder = "0x2222222222222222222222222222222222222222"

export default function openTheClub() {
  prepareFleet("regents_club")
  furnishFleet("regents_club", clubHolder)
}
