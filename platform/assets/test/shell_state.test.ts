import {describe, expect, it} from "vitest"

import {
  brandForShellApp,
  reconcileShellState,
  shellDestinationChanged,
  type ShellState,
} from "../js/shell_state"

const state = (overrides: Partial<ShellState> = {}): ShellState => ({
  routeId: "fleet",
  destination: "/syndicate/1",
  menuOpen: false,
  ...overrides,
})

describe("shell brand reconciliation", () => {
  it("maps shell applications to the canonical RegentUI brands", () => {
    expect(brandForShellApp("product")).toBe("platform")
    expect(brandForShellApp(undefined)).toBe("platform")
  })
})

describe("shell state restoration", () => {
  it("closes the menu and resets local state outside its contexts", () => {
    const current = state({
      routeId: "account",
      destination: "/account",
      menuOpen: true,
    })

    expect(reconcileShellState(current, state())).toEqual(state())
  })

  it("requests top scroll only when the actual destination changes", () => {
    const current = state({routeId: "account", destination: "/account"})

    expect(shellDestinationChanged(current, state({routeId: "fleet", destination: "/syndicate/1"}))).toBe(true)
    expect(shellDestinationChanged(current, state({routeId: "account", destination: "/account"}))).toBe(false)
  })
})
