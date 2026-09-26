/**
 * What all of Keyfleet's motion shares: the timing, the two questions asked
 * before anything moves, the last press, and the moves an island has running.
 */
import type {JSAnimation} from "animejs"

export const SLOW = 280

// The reader asked for less motion in their system settings.
export function still() {
  return matchMedia("(prefers-reduced-motion: reduce)").matches
}

// A click from Enter or Space reports no pointer presses. Keyboard-driven UI
// answers at once rather than animating.
export function byPointer(event: MouseEvent) {
  return event.detail > 0
}

// The last press: the control it reached, when that control has an id, and
// whether a pointer made it. Whatever the press opens asks how it was made,
// and a dialog it opens hands focus back to that control when it closes.
// Safari doesn't focus a link or button when it is clicked, so what has focus
// can't say which control that was.
let last: {control?: string; pointer: boolean} = {pointer: false}

export function notePress(event: MouseEvent) {
  const control = (event.target as Element | null)?.closest?.("a[id], button[id], [tabindex][id]")
  last = {control: control?.id, pointer: byPointer(event)}
}

// A key press, or going back or forward, starts afresh: what opens next
// wasn't opened by the last press.
export function forgetPress() {
  last = {pointer: false}
}

export function pressedControl() {
  return last.control
}

// Whether the last press was a pointer's, asked once by whatever it opened.
export function takePointerPress() {
  const {pointer} = last
  last = {...last, pointer: false}
  return pointer
}

/**
 * The moves an island has running. Each leaves once it ends, or once a newer
 * move on the same thing cuts it short, so a page watched for hours holds
 * only what is moving now. Whatever still moves stops when the island goes.
 */
export type Moves = Set<JSAnimation>

export function play(moves: Moves, move: JSAnimation) {
  moves.forEach(earlier => earlier.cancelled && moves.delete(earlier))
  moves.add(move)
  move.then(() => moves.delete(move))
}

export function stop(moves: Moves) {
  moves.forEach(move => move.revert())
  moves.clear()
}
