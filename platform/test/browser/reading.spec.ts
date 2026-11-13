import {expect, test} from "@playwright/test"

// Every reading page opens inside the app shell for a signed-out visitor, with the
// whole document in the page the server sends first (read here with scripts off, so
// nothing arrives after it), and the section list marks where the reader is. The
// same address still answers an agent asking for Markdown, and the page is drawn
// from that Markdown: its title, then each of its sections. The developer
// documentation's title is Docs, the name its link in the list gives it, while its
// Markdown keeps its own title.
const pages: {path: string; listed: string; heading?: string}[] = [
  {path: "/agents", listed: "/agents"},
  {path: "/agents/dots", listed: "/agents"},
  {path: "/docs", listed: "/docs", heading: "Docs"},
  {path: "/changelog", listed: "/changelog"},
  {path: "/about", listed: "/about"},
  {path: "/privacy", listed: "/privacy"},
  {path: "/terms", listed: "/terms"},
]

test.use({javaScriptEnabled: false})

for (const {path, listed, heading} of pages) {
  test(`${path} opens inside the shell with its whole document, and still answers Markdown`, async ({page, request}) => {
    const answer = await request.get(path, {headers: {accept: "text/markdown"}})
    expect(answer.status()).toBe(200)
    expect(answer.headers()["content-type"]).toContain("text/markdown")
    const [first, ...lines] = (await answer.text()).split("\n")
    expect(first).toMatch(/^# /)
    const sections = lines.filter(line => line.startsWith("## ")).map(line => line.slice(3))

    const response = await page.goto(path)
    expect(response?.status()).toBe(200)
    await expect(page.locator("#shell-header")).toBeVisible()
    await expect(page.locator("#app-shell-scroller > footer.regent-footer")).toBeVisible()
    await expect(page.locator("#route-content h1")).toHaveText(heading ?? first.slice(2))
    await expect(page.locator("#route-content .reading__prose h2")).toHaveText(sections)

    const current = page.locator("#shell-sidebar a[aria-current]")
    await expect(current).toHaveCount(1)
    await expect(current).toHaveAttribute("href", listed)
    await expect(current).toHaveAttribute("aria-current", path === listed ? "page" : "location")
  })
}
