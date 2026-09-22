import {describe, expect, it} from "vitest"

import {run, usage} from "../src/cli.js"

describe("keyfleet", () => {
  it("prints usage with no command", () => {
    expect(run([])).toEqual({exitCode: 0, output: usage})
  })

  it("prints the package version", () => {
    expect(run(["version"]).output).toMatch(/^\d+\.\d+\.\d+\n$/)
  })

  it("refuses an unknown command without changing anything", () => {
    const outcome = run(["launch"])
    expect(outcome.exitCode).toBe(1)
    expect(outcome.output).toContain("Unknown command: launch")
  })
})
