import {execFileSync} from "node:child_process"

// Runs `KeyFleet.BrowserChain` on the browser test server, which
// playwright.chain.config.ts starts as a named node. Each call boots a small
// node that listens for nobody, calls in, prints the answer and stops.
function call(fun: string, args: (string | number)[]): string {
  const target = `KeyFleet.BrowserChain, :${fun}, [${args.map(arg => JSON.stringify(arg)).join(", ")}]`
  const script = `
    case :rpc.call(:"keyfleet_browser@127.0.0.1", ${target}) do
      {:badrpc, reason} -> raise "the browser test server refused: " <> inspect(reason)
      answer -> IO.write(inspect(answer, charlists: :as_lists))
    end`

  return execFileSync(
    "elixir",
    [
      "--name",
      `keyfleet_probe_${process.pid}@127.0.0.1`,
      "--cookie",
      process.env.KEYFLEET_BROWSER_COOKIE!,
      "--erl",
      `-dist_listen false -start_epmd false -erl_epmd_port ${process.env.KEYFLEET_BROWSER_DIST_PORT}`,
      "-e",
      script,
    ],
    {encoding: "utf8"},
  )
}

/** Deploys the fleet the first time; returns how many keys it has sold. */
export const prepareFleet = (fleet: string) => Number(call("prepare!", [fleet]))

/** Sells the fleet's next key to `owner`; returns its number. */
export const sellKey = (fleet: string, owner: string) => Number(call("sell!", [fleet, owner]))

/**
 * Sells a levelled fleet's keys to `owner` up to the last key of the level on
 * sale, and leaves that key unsold. Returns the level and its last key.
 */
export const fillLevel = (fleet: string, owner: string) => JSON.parse(call("fill_level!", [fleet, owner])) as [number, number]

/** Moves a key to `owner`. */
export const moveKey = (fleet: string, key: number, owner: string) => void call("transfer!", [fleet, key, owner])

/** An agent asks to run a key, and its owner approves. */
export const pairKey = (fleet: string, key: number) => void call("pair!", [fleet, key])
