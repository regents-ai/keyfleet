// Invariant: a theme chosen on any switch is written to the cookie the server
// reads and shown on the page at once; the page reads back only the two themes
// it offers and is light until one is chosen, whatever the device asks for; and
// every switch hears each change of the theme on screen once, whoever made it.
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"
import {chooseTheme, chosenTheme, showingTheme, syncTheme, watchTheme, type Theme} from "../js/theme"

type Listener = () => void

let cookies: Map<string, string>
let written: string[]
let dataset: Record<string, string>
let pageObservers: Set<Listener>
let metas: Record<"color-scheme" | "theme-color", {content: string}>
let location: {pathname: string; protocol: string}

beforeEach(() => {
  cookies = new Map()
  written = []
  pageObservers = new Set()
  location = {pathname: "/account", protocol: "http:"}
  metas = {"color-scheme": {content: "light"}, "theme-color": {content: "#e5e3d2"}}
  // The page's own attributes: a change to data-theme reaches every observer, as the browser's would.
  dataset = new Proxy({theme: "light"} as Record<string, string>, {
    set(target, name: string, value: string) {
      const changed = target[name] !== value
      target[name] = value
      if (changed && name === "theme") pageObservers.forEach(observer => observer())
      return true
    },
  })
  vi.stubGlobal("document", {
    documentElement: {dataset},
    get cookie() {
      return [...cookies].map(([name, value]) => `${name}=${value}`).join("; ")
    },
    set cookie(line: string) {
      written.push(line)
      const [pair] = line.split("; ")
      const [name, value] = pair.split("=")
      cookies.set(name, value)
    },
    querySelector: (selector: string) => {
      const meta = metas[selector.includes("color-scheme") ? "color-scheme" : "theme-color"]
      return {setAttribute: (_: string, value: string) => void (meta.content = value)}
    },
  })
  vi.stubGlobal("window", {location})
  vi.stubGlobal("MutationObserver", class {
    constructor(private seen: Listener) {}
    observe() { pageObservers.add(this.seen) }
    disconnect() { pageObservers.delete(this.seen) }
  })
})

afterEach(() => vi.unstubAllGlobals())

describe("choosing a theme", () => {
  it("writes the cookie the server reads and shows the theme at once", () => {
    chooseTheme("dark")
    expect(chosenTheme()).toBe("dark")
    expect(written.at(-1)).toMatch(/^regent_theme=dark; Path=\/; Max-Age=31536000; SameSite=Lax$/)
    expect(dataset.theme).toBe("dark")
    expect(showingTheme()).toBe("dark")
    expect(metas["color-scheme"].content).toBe("dark")
    expect(metas["theme-color"].content).toBe("#161616")

    chooseTheme("light")
    expect(chosenTheme()).toBe("light")
    expect(dataset.theme).toBe("light")
    expect(metas["theme-color"].content).toBe("#e5e3d2")
  })

  it("keeps the cookie to secure connections on a secure page", () => {
    location.protocol = "https:"
    chooseTheme("dark")
    expect(written.at(-1)).toMatch(/; Secure$/)
  })

  it("shows the choice on the homepage as on every page", () => {
    location.pathname = "/"
    for (const theme of ["dark", "light"] as const) {
      chooseTheme(theme)
      expect(dataset.theme).toBe(theme)
    }
  })
})

describe("reading the theme", () => {
  it("accepts only the two themes the page offers", () => {
    for (const value of ["blue", "", "Light", "light;"]) {
      cookies.set("regent_theme", value)
      expect(chosenTheme()).toBeUndefined()
    }
    cookies.clear()
    cookies.set("other", "dark")
    expect(chosenTheme()).toBeUndefined()
  })

  it("is light until a theme is chosen, then the choice", () => {
    dataset.theme = "dark" // a page drawn before the cookie went
    syncTheme()
    expect(dataset.theme).toBe("light")
    expect(metas["color-scheme"].content).toBe("light")
    cookies.set("regent_theme", "dark")
    syncTheme()
    expect(showingTheme()).toBe("dark")
  })
})

describe("watching the theme", () => {
  it("hears each change once, whoever made it, and nothing after it stops", () => {
    const heard: Theme[] = []
    const stop = watchTheme(theme => heard.push(theme))

    chooseTheme("dark") // another switch
    chooseTheme("dark") // the same theme stated again
    syncTheme() // live navigation restating it
    dataset.theme = "light" // the server's next page
    expect(heard).toEqual(["dark", "light"])

    stop()
    chooseTheme("dark")
    expect(heard).toEqual(["dark", "light"])
    expect(pageObservers.size).toBe(0)
  })
})
