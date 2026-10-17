// Manifest-listed public reads and exact signed agent tools. The existing SIWA
// signer supplies proof; browser cookies never authorize these requests.
// page_tools.ts keeps the separately approved wallet-button interaction.

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import {signedTools, type SignedOperation, type SignedInput} from "../vendor/regent_agent_access/signed_tools"

import {inputProblem, type Schema} from "./tool_input"

function signedTransport() {
  return signedTools({origin: window.location.origin,
    trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""],
    audience: manifest.audience, proofHeaders: manifest.proof_headers,
    // Only the signed tools are operations; each is sent with its operation's own inputs.
    operations: manifest.tools.flatMap(entry =>
      "operation_input_schema" in entry ? [{...entry, input_schema: entry.operation_input_schema}] : [],
    ) as unknown as SignedOperation[]})
}

type Entry = {
  name: string
  title: string
  description: string
  input_schema: Schema
  annotations: {readOnlyHint: boolean}
  scope: string
  authentication: string
  state_changing: boolean
}

// The site's refusal, as its API answers one: {"error": {"code", "message", "hint"}}.
type Refusal = {code: string; message: string; hint: string}

type Reply =
  | {ok: true; status: number; data: string}
  | {ok: false; status: number; error: Refusal}
  | {ok: false; status: number; data: string}

type Request = (input: Record<string, string>, signal: AbortSignal | undefined) => Promise<Reply>

// Each tool reads the site's own public document, in the Markdown an agent
// gets when it asks for that page: the About page, the docs, or the open
// fleet directory. A refusal, such as 404 fleet_unknown, is passed on as the
// site gives it: its error when it answers in JSON, and otherwise its words,
// as the directory says it can't be read right now.
const requests: Record<string, Request> = {
  about: (_input, signal) => read("/about", signal),
  docs: (_input, signal) => read("/docs", signal),
  list_fleets: (_input, signal) => read("/fleets.md", signal),
  read_fleet: (input, signal) => read(`/fleets/${encodeURIComponent(input.fleet_id)}.md`, signal),
  list_proposals: (input, signal) => read(`/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/proposals${input.before === undefined ? "" : `?before=${encodeURIComponent(input.before)}`}`, signal, "application/json"),
  read_treasury: (input, signal) => read(`/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/treasury`, signal, "application/json"),
  read_workspace_pulse: (input, signal) => read(`/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/workspace/pulse`, signal, "application/json"),
}

async function read(path: string, signal: AbortSignal | undefined, accept = "text/markdown"): Promise<Reply> {
  const response = await fetch(path, {
    headers: {Accept: accept},
    credentials: "omit",
    cache: "no-store",
    redirect: "error",
    signal,
  })
  if (response.ok) return {ok: true, status: response.status, data: await response.text()}
  if (!response.headers.get("content-type")?.includes("json")) return {ok: false, status: response.status, data: await response.text()}
  const {error} = (await response.json()) as {error: Refusal}
  return {ok: false, status: response.status, error}
}

// JSON imports widen every literal, so the manifest is read as the shape it is written in.
const entries = manifest.tools as unknown as Entry[]

const tools: ModelContextTool[] = entries.filter(entry => entry.scope === "site").map(entry => ({
  name: entry.name,
  title: entry.title,
  description: entry.description,
  inputSchema: entry.input_schema,
  annotations: entry.annotations,
  async execute(input: unknown, {signal}: {signal?: AbortSignal}) {
    if (entry.name === "prepare_agent_request") {
      try {
        const args = input as {operation: string; input: Record<string, unknown>}
        return {ok: true, request: signedTransport().prepare(args.operation, args.input)}
      } catch (error) {
        return {ok: false, error: {code: "invalid_preparation", message: String(error), hint: "Fix the operation or its input, then call again."}}
      }
    }
    if (entry.authentication === "siwa_per_request") {
      try {
        const response = await signedTransport().execute(entry.name, input as SignedInput, signal)
        const data = await response.json()
        return response.ok ? {ok: true, status: response.status, data} : {ok: false, status: response.status, error: data.error}
      } catch (error) {
        return {ok: false, error: {code: "signed_request_failed", message: String(error),
          hint: entry.state_changing ? "Check what happened before you send it again. Keep the same idempotency_key or command_id, and sign the request again."
            : "Prepare this exact request with prepare_agent_request and sign it with your SIWA signer, then call again. If you have no signer, report that as a blocker."}}
      }
    }
    const problem = inputProblem(input, entry.input_schema)
    if (problem) return {ok: false, error: {code: "invalid_input", message: problem, hint: "Fix the call, then call again."}}
    try {
      return await requests[entry.name](input as Record<string, string>, signal)
    } catch (_error) {
      return signal?.aborted
        ? {ok: false, error: {code: "cancelled", message: "The read was cancelled; nothing changed."}}
        : {ok: false, error: {code: "unreachable", message: "The page could not be read. Try again in a moment."}}
    }
  },
}))

// One registration per shown page: register on pageshow, remove on pagehide,
// so a page restored from the back/forward cache never holds two sets. The
// html element's data-webmcp-status says whether the browser holds them all;
// only the latest registration writes it.
export function installPublicTools(): void {
  const status = document.documentElement.dataset
  if (!("modelContext" in document)) {
    status.webmcpStatus = "unsupported"
    return
  }
  let registration: AbortController | undefined

  window.addEventListener("pageshow", () => {
    const current = new AbortController()
    registration = current
    const {signal} = current
    Promise.all(tools.map(tool => document.modelContext.registerTool(tool, {signal})))
      .then(() => document.modelContext.getTools())
      .then(held => {
        if (registration !== current) return
        const names = new Set(held.map(tool => tool.name))
        status.webmcpStatus = tools.every(tool => names.has(tool.name)) ? "connected" : "error"
      })
      .catch((error: unknown) => {
        current.abort()
        if (registration !== current) return
        status.webmcpStatus = "error"
        console.warn("The browser tools could not be offered.", error)
      })
  })
  window.addEventListener("pagehide", () => registration?.abort())
}
