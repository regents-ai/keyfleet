import {furnishFleet, prepareFleet, startPoll} from "./fleet_chain"

// The site as a first-time visitor finds it at launch: the Regents Club open,
// with a post in General, a goal, a task, a proposal and a poll, and Classic #1
// still coming soon. playwright.devices.config.ts runs this once, after its
// server has started and before any spec, so every device sees the same site.
// The specs find what is here through the pages' own links, so they run as
// they are against a real site that holds these things too.
const clubHolder = "0x2222222222222222222222222222222222222222"

export default function openTheClub() {
  prepareFleet("regents_club")
  furnishFleet("regents_club", clubHolder)
  startPoll("regents_club", clubHolder, "Should the fleet take on the research plan next?")
}
