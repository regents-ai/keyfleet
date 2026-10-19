import {execFileSync} from "node:child_process"

// Runs a function of `Keyfleet.BrowserChain`, or of another test module, on
// the browser test server, which playwright.chain.config.ts starts as a named
// node. Each call boots a small node that listens for nobody, calls in,
// prints the answer and stops. An answer that is text is printed as it is.
export function call(fun: string, args: Argument[], module = "Keyfleet.BrowserChain"): string {
  const target = `${module}, :${fun}, [${args.map(literal).join(", ")}]`
  const script = `
    case :rpc.call(:"keyfleet_browser@127.0.0.1", ${target}) do
      {:badrpc, reason} -> raise "the browser test server refused: " <> inspect(reason)
      answer when is_binary(answer) -> IO.write(answer)
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

type Argument = string | number | boolean | Record<string, string>

// An argument written as Elixir: a map's keys and values are strings. A `#`
// is escaped, so text such as a signed body is never read as interpolation.
function literal(arg: Argument): string {
  if (typeof arg === "boolean") return String(arg)
  if (typeof arg === "object") {
    return `%{${Object.entries(arg).map(([key, value]) => `${text(key)} => ${text(value)}`).join(", ")}}`
  }
  return typeof arg === "string" ? text(arg) : JSON.stringify(arg)
}

const text = (value: string) => JSON.stringify(value).replaceAll("#", "\\#")

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

/** A key has `atoms` USDC waiting from now on; any other key's rewards can't be read. */
export const offerRewards = (fleet: string, key: number, atoms: number) =>
  void call("offer_rewards!", [fleet, key, atoms])

/** A key's request for its random draw was turned down, or accepted, from now on. */
export const refuseDraw = (fleet: string, key: number, refused: boolean) =>
  void call("refuse_draw!", [fleet, key, refused])

/** A key's owner gives the browser agent a shard of the key for 30 days. */
export const shardKey = (fleet: string, key: number) => void call("shard!", [fleet, key])

/** The chain records a key's owner issuing `wallet` a shard of the key for `days`. */
export const issueShard = (fleet: string, key: number, wallet: string, days: number) =>
  void call("issue_shard!", [fleet, key, wallet, days])

/** The chain records the shard `wallet` holds of a key ended by `by`. */
export const endShard = (fleet: string, key: number, wallet: string, by: string) =>
  void call("end_shard!", [fleet, key, wallet, by])

/** `owner` has allowed every fleet `atoms` USDC from now on. */
export const allowUsdc = (owner: string, atoms: number) => void call("allow!", [owner, atoms])

/**
 * Gives a deployed fleet a key sold to `owner` that says something in the
 * General room, a goal discussing it and a task assigned to the key in the
 * workspace, and proposal 1. Returns the key.
 */
export const furnishFleet = (fleet: string, owner: string) => Number(call("furnish!", [fleet, owner]))

/** Opens the product pages, or closes them behind the launch gate. */
export const setSurfaces = (open: boolean) => void call("surfaces!", [open])

/** A transaction a page's wallet sent, as the page sent it. */
export type SentTransaction = {from: string; to: string; data: string; value: string}

/** The step sent as `transaction` is included under `hash`; it did what it asked when `succeeded`. */
export const landStep = (hash: string, transaction: SentTransaction, succeeded: boolean) =>
  void call("land!", [hash, transaction, succeeded])

/** Sells the fleet's next key to `owner`, who says `body` in the General room; returns the key. */
export const sayInGeneral = (fleet: string, owner: string, body: string) =>
  Number(call("say!", [fleet, owner, body]))

/** The holder of a Key, by its wallet `owner`, asks the fleet `question` in an hour-long poll; returns the poll's id. */
export const startPoll = (fleet: string, owner: string, question: string) => call("poll!", [fleet, owner, question])
