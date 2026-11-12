/**
 * Every value card's panel, by the name its card carries in `data-value-card`:
 * the homepage's six (`KeyfleetWeb.HomeLive`). This list and `panels/` are
 * Keyfleet's own; `ballot`, `board`, `link` and `rooms` are the template's
 * panels as they are, `fleet` is the one regents.sh shows for Keyfleet, and
 * `ledger` is Keyfleet's.
 */
import {ballot} from "./panels/ballot"
import {board} from "./panels/board"
import {fleet} from "./panels/fleet"
import {ledger} from "./panels/ledger"
import {link} from "./panels/link"
import {rooms} from "./panels/rooms"
import type {ValuePanel} from "./panel"

export const panels: Record<string, ValuePanel> = {
  fleet,
  rooms,
  board,
  link,
  ballot,
  ledger,
}
