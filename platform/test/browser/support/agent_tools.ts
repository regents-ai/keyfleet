import {expect, type Page} from "@playwright/test"

import {call} from "./fleet_chain"

// No browser Playwright drives has WebMCP yet, so this stands in for the
// browser's half: a document.modelContext that holds the tools a page
// registers, refuses a second tool of a name it holds, as the draft does, and
// lets one go when the signal it was registered with is aborted. A test then
// calls a held tool's execute as an agent's browser would. This proves the
// page's own registration and tools, not a real browser's discovery of them.

type HeldTool = {name: string; execute(input: unknown, client: {signal?: AbortSignal}): Promise<unknown>}

declare global {
  interface Document {
    readonly modelContext: {getTools(): Promise<HeldTool[]>}
  }
}

/** Gives every page the browser opens from now on its own stand-in document.modelContext. */
export async function installModelContext(page: Page) {
  await page.addInitScript(() => {
    const held = new Map<string, HeldTool>()
    Object.defineProperty(document, "modelContext", {
      value: {
        async registerTool(tool: HeldTool, {signal}: {signal: AbortSignal}) {
          if (signal.aborted) throw signal.reason
          if (held.has(tool.name)) throw new DOMException(`${tool.name} is already registered`, "InvalidStateError")
          held.set(tool.name, tool)
          signal.addEventListener("abort", () => held.get(tool.name) === tool && held.delete(tool.name), {once: true})
        },
        async getTools() {
          return [...held.values()]
        },
      },
    })
  })
}

/** The names of the tools the open page holds. */
export const heldTools = (page: Page) =>
  page.evaluate(async () => (await document.modelContext.getTools()).map(tool => tool.name))

/** Calls the page's tool `name` with `input`, as an agent's browser does, and answers what it returns. */
export const callTool = (page: Page, name: string, input: unknown) =>
  page.evaluate(
    async ({name, input}) => {
      const tool = (await document.modelContext.getTools()).find(held => held.name === name)
      if (!tool) throw new Error(`The page holds no ${name} tool.`)
      return tool.execute(input, {})
    },
    {name, input},
  ) as Promise<Answer>

/** The exact request a page's signed tool asks the browser host to sign. */
type Prepared = {operation: string; audience: string; origin: string; method: string; path: string; body?: string}

/** What a tool answers: the site's answer as `data`, or its refusal in the site's one error shape. */
export type Answer = {
  ok: boolean
  status?: number
  data?: any
  error?: {code: string; message: string; hint?: string}
}

// The page's stand-in browser host, by page: the agent whose own signer signs
// for it, and, while a spec only wants the request a tool builds, where to keep
// it instead of signing.
const hosts = new WeakMap<Page, {agent: string; keep?: Prepared[]}>()

// Gives the page a window.regentsSign, as regents browser does, that signs the
// exact request a signed tool built with `agent`'s own signer.
async function host(page: Page, agent: string, keep?: Prepared[]) {
  const given = hosts.has(page)
  hosts.set(page, {agent, keep})
  if (given) return
  await page.exposeFunction("regentsSign", (request: Prepared) => {
    const {agent, keep} = hosts.get(page)!
    if (!keep) return {headers: signRequest(agent, request)}
    keep.push(request)
    return {error: {code: "kept", message: "The test kept the request; nothing was sent."}}
  })
}

/**
 * Calls the signed tool `name` as an agent does: the page builds the exact
 * request, `agent`'s own signer signs it, and the page sends it with that proof.
 */
export async function callSigned(page: Page, agent: string, name: string, input: Record<string, unknown>) {
  await host(page, agent)
  return callTool(page, name, input)
}

/**
 * Sends the request the page builds for the signed tool `name` straight to
 * the site, signed afresh by `agent`, as a signed HTTP client sends it; answers
 * its status and body, to set beside what the tool answers.
 */
export async function sendSigned(page: Page, agent: string, name: string, input: Record<string, unknown>) {
  const kept: Prepared[] = []
  await host(page, agent, kept)
  const refused = await callTool(page, name, input)
  expect(refused.error?.code, JSON.stringify(refused)).toBe("kept")
  const [request] = kept
  const response = await page.request.fetch(new URL(request.path, request.origin).href, {
    method: request.method,
    headers: {...signRequest(agent, request), "content-type": "application/json"},
    data: request.body,
  })
  return {status: response.status(), data: await response.json()}
}

const agents = "Keyfleet.BrowserAgents"

/** Makes an agent with a signer of its own; returns its wallet. */
export const newAgent = () => call("new_agent!", [], agents)

/** Pairs `agent` with the person whose wallet is `person`. */
export const pairAgent = (agent: string, person: string) => void call("pair!", [agent, person], agents)

/** A pairing code from the person whose wallet is `person`, as Pair New Agent shows one. */
export const pairingCode = (person: string) => call("pairing_code!", [person], agents)

/** Pairs `agent`, called `name`, with the person signed in to Privy as `person`. */
export const pairPerson = (agent: string, person: string, name: string) =>
  void call("pair_person!", [agent, person, name], agents)

/** Pairs `agent`, called `name`, with the `code` a pairing box shows. */
export const useCode = (agent: string, code: string, name: string) =>
  void call("use_code!", [agent, code, name], agents)

/** `agent`'s daily run checks in with the fleet, as its scheduled sync does; no open page is told. */
export const checkInDaily = (agent: string, fleet: string) => void call("check_in!", [agent, fleet], agents)

// The proof headers `agent`'s signer makes for the request a page built.
function signRequest(agent: string, {origin, method, path, body}: Prepared): Record<string, string> {
  return JSON.parse(call("sign!", [agent, body === undefined ? {origin, method, path} : {origin, method, path, body}], agents))
}
