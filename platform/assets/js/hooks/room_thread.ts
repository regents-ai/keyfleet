import type {Hook} from "../hook_composition"

type RoomThreadHook = {
  el: HTMLElement
  room?: HTMLElement
  atEnd: boolean
  follow?: () => void
  watch?: ResizeObserver
  onScroll?: (event: Event) => void
  onSubmit?: () => void
}

// How near the end still counts as at it: what zoom loses to rounding.
const NEAR = 2

/**
 * Whether the reader is at the room's end: the room scrolled to its end, on a
 * wide screen where it scrolls in its own column, and its foot on the screen,
 * on a narrow one where it scrolls with the page.
 */
function atEnd(room: HTMLElement) {
  const {bottom} = room.getBoundingClientRect()
  return room.scrollHeight - room.scrollTop - room.clientHeight <= NEAR && bottom >= 0 && bottom <= innerHeight + NEAR
}

/** The newest post at the foot of the screen, with the box to write in under it. */
function toEnd(room: HTMLElement) {
  room.scrollTop = room.scrollHeight
  const {bottom} = room.getBoundingClientRect()
  if (bottom > innerHeight || bottom < 0) room.scrollIntoView({block: "end", behavior: "instant"})
}

/**
 * A room's posts, which open at the newest one whenever the room comes to be
 * shown: the element is the room's own, so opening another room, coming back
 * to this one or loading the page mounts it afresh. While the reader is at the
 * newest post, anything that changes the room's size keeps them there: a new
 * post as it slides in, a picture loading, the window resizing, a refusal
 * under the posts. Only the reader scrolling up leaves the end: a scroll that
 * leaves the room's column or the page higher than the page last put it. A
 * post sliding in can overshoot and settle back, and the page follows it
 * down and up again, so where the page puts each box is noted as it does.
 * Once the reader has left, nothing moves them until they are back at the
 * end, send a post of their own or the page reconnects and draws the room
 * again.
 */
export const RoomThread: Hook = {
  mounted(this: RoomThreadHook) {
    const room = this.el.closest<HTMLElement>(".rooms-thread")!
    // Where each box holding the room last stood, after the page or the
    // reader moved it.
    const tops = new WeakMap<Element, number>()
    this.room = room
    this.atEnd = true
    this.follow = () => {
      toEnd(room)
      for (let box: Element | null = room; box; box = box.parentElement) tops.set(box, box.scrollTop)
    }
    this.onScroll = event => {
      const scroller = event.target instanceof Element ? event.target : document.scrollingElement!
      if (!scroller.contains(room)) return
      const up = scroller.scrollTop < (tops.get(scroller) ?? scroller.scrollTop)
      tops.set(scroller, scroller.scrollTop)
      this.atEnd = atEnd(room) || (this.atEnd && !up)
    }
    this.onSubmit = () => {
      this.atEnd = true
      this.follow!()
    }
    this.watch = new ResizeObserver(() => this.atEnd && this.follow!())
    for (const box of [this.el, room.querySelector(".rooms-foot")!, room]) this.watch.observe(box)
    // Scrolls of the room's column and of the page, neither of which bubbles.
    document.addEventListener("scroll", this.onScroll, {capture: true, passive: true})
    room.addEventListener("submit", this.onSubmit)
    this.follow()
  },

  reconnected(this: RoomThreadHook) {
    this.atEnd = true
    this.follow!()
  },

  destroyed(this: RoomThreadHook) {
    this.watch?.disconnect()
    document.removeEventListener("scroll", this.onScroll!, {capture: true})
    this.room?.removeEventListener("submit", this.onSubmit!)
  },
}
