/**
 * Time as the Atlas heat draws it: hours since the start of 2024, a Monday at
 * midnight UTC, so an hour, a day and a week from its Monday each start on a
 * whole multiple of their length and line up with the buckets the page counts
 * by (`Keyfleet.Atlas.Span`). Everything here is in UTC, as the page's counts
 * are.
 */

export const EPOCH = Date.UTC(2024, 0, 1)
export const HOUR = 3_600_000

/** Hours since the epoch, of a moment in milliseconds. */
export const hourOf = (ms: number) => (ms - EPOCH) / HOUR

/** A moment in milliseconds, of hours since the epoch. */
export const msOf = (hour: number) => EPOCH + hour * HOUR

/** The windows a reader names in the address, shortest first. */
export type Window = "day" | "week" | "month" | "year"

/**
 * The levels the picture zooms through, broadest first: a square a week, a
 * day or an hour, each read from the page a tile of buckets at a time. Inside
 * an hour, the things changed in it are shown as cards.
 */
export type Level = {
  readonly span: "week" | "day" | "hour"
  readonly hours: number
  readonly tile: number
  readonly word: string
}

export const LEVELS: readonly Level[] = [
  {span: "week", hours: 168, tile: 52 * 168, word: "Weeks"},
  {span: "day", hours: 24, tile: 56 * 24, word: "Days"},
  {span: "hour", hours: 1, tile: 72, word: "Hours"},
]

/** The zoom, in CSS pixels an hour, from which days and then hours are shown. */
export const DAYS_FROM = 0.5
export const HOURS_FROM = 12

/** The level shown at `zoom`, by its place in `LEVELS`. */
export const levelAt = (zoom: number) => (zoom < DAYS_FROM ? 0 : zoom < HOURS_FROM ? 1 : 2)

/** The start of the bucket `hours` long holding `hour`. */
export const bucketOf = (hour: number, hours: number) => Math.floor(hour / hours) * hours

/** The window of `span` holding `hour`, as its first hour and the hour after its last. */
export function windowOf(span: Window, hour: number): [number, number] {
  if (span === "day" || span === "week") {
    const length = span === "day" ? 24 : 168
    const start = bucketOf(hour, length)
    return [start, start + length]
  }
  const at = new Date(msOf(hour))
  const [year, month] = [at.getUTCFullYear(), at.getUTCMonth()]
  return span === "month"
    ? [hourOf(Date.UTC(year, month, 1)), hourOf(Date.UTC(year, month + 1, 1))]
    : [hourOf(Date.UTC(year, 0, 1)), hourOf(Date.UTC(year + 1, 0, 1))]
}

/** The window a stretch of `hours` across the screen is read as. */
export const windowFor = (hours: number): Window =>
  hours > 62 * 24 ? "year" : hours > 10 * 24 ? "month" : hours > 30 ? "week" : "day"

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const MONTH_NAMES = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
]
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

const two = (value: number) => String(value).padStart(2, "0")

/** One bucket, as the page names a window: "Week of 9 Nov 2026", "13 Nov 2026, 14:00 UTC". */
export function bucketLabel(span: Level["span"], hour: number) {
  const at = new Date(msOf(hour))
  const day = `${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]} ${at.getUTCFullYear()}`
  if (span === "week") return `Week of ${day}`
  if (span === "day") return day
  return `${day}, ${two(at.getUTCHours())}:00 UTC`
}

/** The clock time of a moment in milliseconds, in UTC. */
export function clockOf(ms: number) {
  const at = new Date(ms)
  return `${two(at.getUTCHours())}:${two(at.getUTCMinutes())}`
}

/** The day holding `hour`, as the address names it. */
export function dateOf(hour: number) {
  return new Date(msOf(bucketOf(hour, 24))).toISOString().slice(0, 10)
}

/** What the time along the top says at its left edge, at each level. */
export function contextOf(level: number, hour: number) {
  const at = new Date(msOf(hour))
  if (level === 0) return String(at.getUTCFullYear())
  if (level === 1) return `${MONTH_NAMES[at.getUTCMonth()]} ${at.getUTCFullYear()}`
  return `${DAYS[at.getUTCDay()]} ${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]} ${at.getUTCFullYear()}`
}

/**
 * Each mark along the top between `from` and `to` at `level` and `zoom`, as
 * its hour and its words, far enough apart to read: months (or years alone)
 * over weeks; days (or Mondays alone) over days; and hours a step apart over
 * hours, each midnight named by its day.
 */
export function eachTick(
  level: number,
  from: number,
  to: number,
  zoom: number,
  emit: (hour: number, text: string) => void,
) {
  if (level === 0) {
    const yearsOnly = 730 * zoom < 34
    const start = new Date(msOf(from))
    let [year, month] = [start.getUTCFullYear(), yearsOnly ? 0 : start.getUTCMonth()]
    for (;;) {
      const hour = hourOf(Date.UTC(year, month, 1))
      if (hour > to) return
      emit(hour, month === 0 ? String(year) : MONTHS[month])
      month += yearsOnly ? 12 : 1
      if (month > 11) [year, month] = [year + 1, month - 12]
    }
  }
  if (level === 1) {
    const daily = 24 * zoom >= 30
    const step = daily ? 24 : 168
    for (let hour = bucketOf(from, step); hour <= to; hour += step) {
      const at = new Date(msOf(hour))
      const date = at.getUTCDate()
      emit(hour, daily && date !== 1 ? String(date) : `${date} ${MONTHS[at.getUTCMonth()]}`)
    }
    return
  }
  const step = [1, 2, 3, 6, 12, 24].find(hours => hours * zoom >= 52) ?? 24
  for (let hour = bucketOf(from, step); hour <= to; hour += step) {
    const at = new Date(msOf(hour))
    const clock = at.getUTCHours()
    emit(hour, clock === 0 ? `${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]}` : `${two(clock)}:00`)
  }
}
