// Manifest-listed public reads and exact signed agent tools. The existing SIWA
// signer supplies proof; browser cookies never authorize these requests.
// page_tools.ts keeps the separately approved wallet-button interaction.
// public_tools.ts loads this file only in a browser that has its own agent.

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import {signedTools, type SignedOperation, type SignedInput} from "../vendor/regent_agent_access/signed_tools"

import {described} from "./tool_description"
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
  requires: string
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
// fleet directory. A refusal is passed on as the site gives it: its error when
// it answers in JSON, and otherwise its words, such as a missing fleet's
// Markdown 404 that links every fleet.
const requests: Record<string, Request> = {
  about: (_input, signal) => read("/about", signal),
  docs: (_input, signal) => read("/docs", signal),
  fleets_list: (_input, signal) => read("/fleets.md", signal),
  fleets_show: (input, signal) => read(`/fleets/${encodeURIComponent(input.fleet_id)}.md`, signal),
  proposals_list: (input, signal) => read(`/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/proposals${input.before === undefined ? "" : `?before=${encodeURIComponent(input.before)}`}`, signal, "application/json"),
  treasury_show: (input, signal) => read(`/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/treasury`, signal, "application/json"),
  workspace_pulse: (input, signal) => read(`/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/workspace/pulse`, signal, "application/json"),
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

export const tools: ModelContextTool[] = entries.filter(entry => entry.scope === "site").map(entry => ({
  name: entry.name,
  title: entry.title,
  description: described(entry),
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
        // fetch fails with a TypeError, or an AbortError when cancelled; every
        // other error is the transport refusing the call before anything is sent.
        const sent = error instanceof TypeError || (error as Error).name === "AbortError"
        if (!sent) return {ok: false, error: {code: "signed_call_refused", message: String(error),
          hint: "Nothing was sent. Prepare this exact request with prepare_agent_request, sign it with your SIWA signer, then call again with input, request and proof. If you have no signer, report that as a blocker."}}
        return {ok: false, error: {code: "signed_request_failed", message: String(error),
          hint: entry.state_changing ? "Check what happened before you send it again. Keep the same idempotency_key or command_id, and sign the request again."
            : "Try again in a moment."}}
      }
    }
    const problem = inputProblem(input, entry.input_schema)
    if (problem) return {ok: false, error: {code: "invalid_input", message: problem, hint: "Fix the call, then call again."}}
    try {
      return await requests[entry.name](input as Record<string, string>, signal)
    } catch (_error) {
      return signal?.aborted
        ? {ok: false, error: {code: "cancelled", message: "The read was cancelled; nothing changed.", hint: "Call again when you want it."}}
        : {ok: false, error: {code: "unreachable", message: "The page could not be read.", hint: "Try again in a moment."}}
    }
  },
}))
