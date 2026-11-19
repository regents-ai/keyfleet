import type {Hook} from "../hook_composition"

type RoomThreadHook = {
  el: HTMLElement
  room?: HTMLElement
  atEnd: boolean
  watch?: ResizeObserver
  onScroll?: () => void
  onSubmit?: () => void
}

// How near the end still counts as at it: what zoom loses to rounding.
const NEAR = 2

/**
 * Whether the reader is at the room's newest post: the posts scrolled to
 * their end, on a wide screen where they scroll on their own, and the foot of
 * the room on the screen, on a narrow one where it scrolls with the page.
 */
function atEnd(posts: HTMLElement, room: HTMLElement) {
  const {bottom} = room.getBoundingClientRect()
  return posts.scrollHeight - posts.scrollTop - posts.clientHeight <= NEAR && bottom >= 0 && bottom <= innerHeight + NEAR
}

/** The newest post at the foot of the screen, with the box to write in under it. */
function toEnd(posts: HTMLElement, room: HTMLElement) {
  posts.scrollTop = posts.scrollHeight
  const {bottom} = room.getBoundingClientRect()
  if (bottom > innerHeight || bottom < 0) room.scrollIntoView({block: "end", behavior: "instant"})
}

/**
 * A room's posts, which open at the newest one whenever the room comes to be
 * shown: the element is the room's own, so opening another room, coming back
 * to this one or loading the page mounts it afresh. While the reader is at the
 * newest post, anything that changes the room's size keeps them there: a new
 * post, a picture loading, the window resizing, a refusal under the posts.
 * Once they scroll up to read, nothing moves them, until they send a post of
 * their own or the page reconnects and draws the room again.
 */
export const RoomThread: Hook = {
  mounted(this: RoomThreadHook) {
    const posts = this.el
    const room = posts.closest<HTMLElement>(".rooms-thread")!
    this.room = room
    this.atEnd = true
    this.onScroll = () => (this.atEnd = atEnd(posts, room))
    this.onSubmit = () => {
      this.atEnd = true
      toEnd(posts, room)
    }
    this.watch = new ResizeObserver(() => this.atEnd && toEnd(posts, room))
    for (const box of [posts, posts.querySelector("ol")!, room]) this.watch.observe(box)
    // Scrolls of the posts and of the page, neither of which bubbles.
    document.addEventListener("scroll", this.onScroll, {capture: true, passive: true})
    room.addEventListener("submit", this.onSubmit)
    toEnd(posts, room)
  },

  reconnected(this: RoomThreadHook) {
    this.atEnd = true
    toEnd(this.el, this.room!)
  },

  destroyed(this: RoomThreadHook) {
    this.watch?.disconnect()
    document.removeEventListener("scroll", this.onScroll!, {capture: true})
    this.room?.removeEventListener("submit", this.onSubmit!)
  },
}
