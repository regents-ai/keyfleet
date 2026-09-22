import {createRequire} from "node:module"

const {version} = createRequire(import.meta.url)("../package.json") as {version: string}

export const usage = `Usage: keyfleet <command>

Commands:
  version   Print the CLI version
  help      Show this message
`

export interface Outcome {
  readonly exitCode: number
  readonly output: string
}

/** Resolves one invocation to what it prints and how it exits; no side effects. */
export function run(args: readonly string[]): Outcome {
  switch (args[0]) {
    case "version":
    case "--version":
      return {exitCode: 0, output: `${version}\n`}
    case undefined:
    case "help":
    case "--help":
      return {exitCode: 0, output: usage}
    default:
      return {exitCode: 1, output: `Unknown command: ${args[0]}\n\n${usage}`}
  }
}
