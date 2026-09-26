/**
 * What all of Keyfleet's motion shares: the timing, the two questions asked
 * before anything moves, the last press, and the one way a move is played.
 */
import {animate, utils, type AnimationParams, type JSAnimation} from "animejs"

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

// Whether the last press was a pointer's, without taking the answer: a page
// change asks, and what the new page opens may ask again.
export function lastPressByPointer() {
  return last.pointer
}

// Whether the last press was a pointer's, asked once by whatever it opened.
export function takePointerPress() {
  const {pointer} = last
  last = {...last, pointer: false}
  return pointer
}

// Anime.js hands an element back to its stylesheet by restoring the inline
// style it found when the animation began. One begun over another's
// half-way frame would end on that frame, so each run first puts its
// elements back as they were before the last run on them began. Every run
// then starts from rest, and ends there with no inline style left behind.
// A finished run is forgotten, so nothing later puts back its old snapshot.
// `play` owns `onComplete`; anything to do afterwards chains on `.then()`.
const playing = new WeakMap<Element, JSAnimation>()

export function play(targets: Element | Element[], params: AnimationParams) {
  const els = [targets].flat()
  for (const el of els) playing.get(el)?.revert()
  const animation = animate(els, {
    ...params,
    onComplete: done => {
      utils.cleanInlineStyles(done)
      for (const el of els) if (playing.get(el) === done) playing.delete(el)
    },
  })
  for (const el of els) playing.set(el, animation)
  return animation
}

// Puts one element back at rest, if a move is still running on it.
export function rest(el: Element) {
  playing.get(el)?.revert()
  playing.delete(el)
}

// An island's moves stop when it goes: whatever still moves inside its
// element is put back at rest.
export function stop(root: Element) {
  for (const el of [root, ...root.querySelectorAll("*")]) rest(el)
}
