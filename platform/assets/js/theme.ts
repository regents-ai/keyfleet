/**
 * The colour theme. Every page is light until the visitor chooses, whatever the
 * device asks for (Sean, 19 Oct 2026: "I want it default light mode"), and the
 * server always states the theme on the page. A choice is written to the cookie
 * the server reads, so the next page is drawn in it, and restated on the page at
 * once.
 *
 * Every theme switch reads and chooses through here, and each one follows a
 * change made anywhere: by another switch or by live navigation.
 */

export type Theme = "light" | "dark"

export const THEME_COOKIE = "regent_theme"
const themeMaxAge = 60 * 60 * 24 * 365
const themeColors: Record<Theme, string> = {dark: "#161616", light: "#e5e3d2"}

/** The theme the visitor chose, from the cookie; none until they choose. */
export function chosenTheme(): Theme | undefined {
  const prefix = `${THEME_COOKIE}=`
  const value = document.cookie
    .split("; ")
    .find(cookie => cookie.startsWith(prefix))
    ?.slice(prefix.length)

  return value === "light" || value === "dark" ? value : undefined
}

/** The theme on screen, as the page states it. */
export function showingTheme(): Theme {
  return document.documentElement.dataset.theme === "dark" ? "dark" : "light"
}

/**
 * Live navigation keeps the document, so each page restates its theme: the
 * visitor's choice, or light until they choose.
 */
export function syncTheme(): void {
  const theme = chosenTheme() ?? "light"
  document.documentElement.dataset.theme = theme
  document.querySelector('meta[name="color-scheme"]')?.setAttribute("content", theme)
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", themeColors[theme])
}

/** Saves the visitor's choice for every later page and shows it on this one. */
export function chooseTheme(theme: Theme): void {
  const secure = window.location.protocol === "https:" ? "; Secure" : ""
  document.cookie = `${THEME_COOKIE}=${theme}; Path=/; Max-Age=${themeMaxAge}; SameSite=Lax${secure}`
  syncTheme()
}

/**
 * Calls `listener` whenever the theme on screen changes, whoever changed it, and
 * returns the way to stop. It is never called for a restatement of the theme
 * already showing.
 */
export function watchTheme(listener: (theme: Theme) => void): () => void {
  let last = showingTheme()
  const page = new MutationObserver(() => {
    const next = showingTheme()
    if (next === last) return
    last = next
    listener(next)
  })
  page.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  return () => page.disconnect()
}
