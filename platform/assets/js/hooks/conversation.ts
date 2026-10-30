import type {Hook} from "../hook_composition"

type ConversationHook = Hook & {
  el: HTMLElement
  observer?: MutationObserver
  keydown?: (event: KeyboardEvent) => void
  submitted?: () => void
  scrolled?: (event: Event) => void
  scroller?: HTMLElement | null
  resized?: ResizeObserver
  atNewest: boolean
  toNewest(): void
}

// A message from the same writer within five minutes of their last one sits
// under that one's name and picture.
const GROUP_SECONDS = 5 * 60

// How near its newest message the reader may be and still be kept there as
// messages arrive.
const NEWEST_SLACK = 24

/**
 * One conversation: a room's, or two Keys' direct messages. Marks each message
 * that continues the one before it (`data-continued`, kept through patches by
 * the message's `JS.ignore_attributes`), sends the message box with Enter
 * (Shift+Enter, and Enter on a touch screen, start a new line) and shows the
 * newest message after a send. A reader at the newest message stays there as
 * messages arrive and as they are grouped; a reader who has scrolled back is
 * left where they are. Each room or pair of Keys brings a list of its own,
 * which starts at its newest message.
 */
export const Conversation: Hook = {
  mounted(this: ConversationHook) {
    // The list is replaced while the conversation stays when another room
    // opens in its place, so it is looked up each time.
    // Posts, pictures and the message box change height after they arrive
    // (a move settling, the box emptying), so a reader at the newest message
    // is kept there whenever the list or its frame changes size.
    this.resized = new ResizeObserver(() => {
      if (this.atNewest) this.toNewest()
    })
    const regroup = () => {
      const scroller = this.el.querySelector<HTMLElement>("[data-conversation-scroller]")
      if (scroller !== this.scroller) {
        this.resized?.disconnect()
        this.scroller = scroller
        this.atNewest = true
        if (scroller) {
          this.resized?.observe(scroller)
          for (const child of scroller.children) this.resized?.observe(child)
        }
      }
      const list = this.el.querySelector<HTMLElement>("[data-conversation-messages]")
      if (list) group(list)
      if (this.atNewest) this.toNewest()
    }
    regroup()
    this.observer = new MutationObserver(regroup)
    this.observer.observe(this.el, {childList: true, subtree: true})

    this.keydown = event => {
      const box = event.target
      if (!(box instanceof HTMLTextAreaElement) || !box.form || !this.el.contains(box)) return
      // Safari ends a composition (Japanese, Chinese) with an Enter whose
      // `isComposing` is already false, marked by key code 229.
      if (event.key !== "Enter" || event.shiftKey || event.isComposing || event.keyCode === 229) return
      if (window.matchMedia("(pointer: coarse)").matches) return
      event.preventDefault()
      box.form.requestSubmit()
    }
    this.el.addEventListener("keydown", this.keydown)

    // The list's column runs bottom up, so its scroll offset counts back from
    // the newest message.
    this.scrolled = event => {
      if (!(event.target instanceof HTMLElement)) return
      if (!event.target.matches("[data-conversation-scroller]")) return
      this.atNewest = Math.abs(event.target.scrollTop) <= NEWEST_SLACK
    }
    this.el.addEventListener("scroll", this.scrolled, true)

    // The newest message is at the bottom, which is where the list rests.
    this.submitted = () => {
      this.atNewest = true
      this.toNewest()
    }
    this.el.addEventListener("submit", this.submitted)
  },

  toNewest(this: ConversationHook) {
    this.scroller?.scrollTo({top: this.scroller.scrollHeight})
  },

  destroyed(this: ConversationHook) {
    this.observer?.disconnect()
    this.resized?.disconnect()
    if (this.keydown) this.el.removeEventListener("keydown", this.keydown)
    if (this.submitted) this.el.removeEventListener("submit", this.submitted)
    if (this.scrolled) this.el.removeEventListener("scroll", this.scrolled, true)
  },
}

// A line that is not a message, such as the note that a room was named,
// carries no `data-author` and ends the run before it.
export function group(list: HTMLElement): void {
  let previous: HTMLElement | null = null
  for (const line of list.querySelectorAll<HTMLElement>(":scope > li")) {
    line.toggleAttribute("data-continued", continues(previous, line))
    previous = line
  }
}

function continues(previous: HTMLElement | null, line: HTMLElement): boolean {
  const author = line.dataset.author
  if (!previous || !author || previous.dataset.author !== author) return false
  return Number(line.dataset.at) - Number(previous.dataset.at) < GROUP_SECONDS
}
