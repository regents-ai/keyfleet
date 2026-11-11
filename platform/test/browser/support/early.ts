/**
 * Whether the scripts a page asked for are the key roller and the pieces it shares with the
 * site's other scripts, and nothing else: not the app, and not sign-in.
 */
export function rollerOnly(requested: string[]): boolean {
  const scripts = requested.map(url => new URL(url).pathname).filter(path => path.endsWith(".js"))
  return scripts.includes("/assets/js/key_roller.js") && scripts.every(path => /^\/assets\/js\/(key_roller|chunks\/chunk-[A-Z0-9]+)\.js$/.test(path))
}
