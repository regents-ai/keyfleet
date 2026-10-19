import type {Hook} from "../hook_composition"

type PollCountdownHook = {el: HTMLElement; gap: number; seen: string | undefined; timer?: number}

/**
 * The time an open poll has left, written again as it changes. The page
 * sends the poll's closing time and its own clock as it read the poll
 * (`data-closes-at`, `data-now`), so a phone whose clock is wrong still counts
 * down to the right moment. The words match what the page writes
 * (`KeyfleetWeb.PollsLive`), so nothing jumps as the hook takes over.
 *
 * It only writes words, once a second at most, and never moves anything, so
 * a reader who asked for less motion sees the same as everyone. When the
 * time runs out it says "Closing…" and waits; the page itself draws the
 * closed poll a moment later.
 */
function left(seconds: number, format: string | undefined) {
  if (format === "minutes") {
    return seconds < 60 ? "Less than a minute left" : `${count(Math.floor(seconds / 60), "minute")} left`
  }
  if (seconds <= 0) return "Closing…"
  if (seconds < 60) return `${count(seconds, "second")} left`
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")} left`
}

const count = (n: number, one: string) => `${n} ${n === 1 ? one : `${one}s`}`

function draw(hook: PollCountdownHook) {
  window.clearTimeout(hook.timer)
  const {closesAt, now, format} = hook.el.dataset

  // The gap between this clock and the page's is taken again only when the
  // page sends a new reading of its own clock.
  if (now !== hook.seen) {
    hook.seen = now
    hook.gap = Number(now) - Date.now()
  }

  const remaining = Number(closesAt) - (Date.now() + hook.gap)
  const seconds = Math.trunc(remaining / 1000)
  const words = left(seconds, format)
  if (hook.el.textContent !== words) hook.el.textContent = words

  // Under a minute the list's words no longer change, and nor do the
  // poll's once it says "Closing…".
  if (seconds <= 0 || (format === "minutes" && seconds < 60)) return

  // The next whole second of what is left, when the words may change.
  hook.timer = window.setTimeout(() => draw(hook), (remaining % 1000) + 1)
}

export const PollCountdown: Hook = {
  mounted(this: PollCountdownHook) {
    draw(this)
  },

  updated(this: PollCountdownHook) {
    draw(this)
  },

  destroyed(this: PollCountdownHook) {
    window.clearTimeout(this.timer)
  },
}
