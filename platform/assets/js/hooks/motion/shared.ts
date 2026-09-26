/**
 * What all of Keyfleet's motion shares: the timing and curve, the two
 * questions asked before anything moves, and the last press, so motion that
 * starts after the page answers a press knows how that press was made.
 */
import {cubicBezier} from "animejs"

export const SLOW = 280

export const EASE_OUT = cubicBezier(0.23, 1, 0.32, 1)

// The reader asked for less motion in their system settings.
export function still() {
  return matchMedia("(prefers-reduced-motion: reduce)").matches
}

// A click from Enter or Space reports no pointer presses. Keyboard-driven UI
// answers at once rather than animating.
export function byPointer(event: MouseEvent) {
  return event.detail > 0
}

let pointerPress = false

// Every click says whether it came from a pointer; any key press forgets it.
export function notePress(event: MouseEvent) {
  pointerPress = byPointer(event)
}

export function forgetPress() {
  pointerPress = false
}

// Whether the last press was a pointer's, asked once by whatever it opened.
export function takePointerPress() {
  const pressed = pointerPress
  pointerPress = false
  return pressed
}
