// Manifest-listed public reads and exact signed agent tools. The existing SIWA
// signer supplies proof; browser cookies never authorize these requests.
// page_tools.ts keeps the separately approved wallet-button interaction.
// public_tools.ts loads this file only in a browser that has its own agent.

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import {signedTools, type SignedOperation, type SignedInput} from "../vendor/regent_agent_access/signed_tools"

import {described} from "./tool_description"
import {inputProblem, type Schema} from "./tool_input"
import {report, visitId} from "./visit_log"

function signedTransport() {
  return signedTools({origin: window.location.origin,
    trustedOrigins: [document.querySelector<HTMLMetaElement>('meta[name="agent-request-origin"]')?.content ?? ""],
    audience: manifest.audience, proofHeaders: manifest.proof_headers,
    requestHeaders: client,
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
  operation_id_field?: string
}

// The site's refusal, as its API answers one: {"error": {"code", "message", "hint"}}.
type Refusal = {code: string; message: string; hint: string}

type Reply =
  | {ok: true; status: number; data: string}
  | {ok: false; status: number; error: Refusal}
  | {ok: false; status: number; data: string}

// Each tool reads the site's own public document, by the path it asks: the
// Markdown an agent gets when it asks for that page (the About page, the docs,
// or the open fleet directory), or the API's JSON. A refusal is passed on as
// the site gives it: its error when it answers in JSON, and otherwise its
// words, such as a missing fleet's Markdown 404 that links every fleet.
const paths: Record<string, (input: Record<string, string>) => string> = {
  about: () => "/about",
  docs: () => "/docs",
  fleets_list: () => "/fleets.md",
  fleets_show: input => `/fleets/${encodeURIComponent(input.fleet_id)}.md`,
  proposals_list: input => `/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/proposals${input.before === undefined ? "" : `?before=${encodeURIComponent(input.before)}`}`,
  treasury_show: input => `/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/treasury`,
  workspace_pulse: input => `/api/v1/fleets/${encodeURIComponent(input.fleet_id)}/workspace/pulse`,
}

// Every call names its tool and this visit, so the site's log can put the call
// beside the rest of the visit (KeyfleetWeb.VisitLog). Neither is a credential.
function client(tool: string): Record<string, string> {
  const visit = visitId()
  return {"x-regent-client": `webmcp/${tool}`, ...(visit && {"x-regent-visit": visit})}
}

async function read(tool: string, path: string, signal: AbortSignal | undefined): Promise<Reply> {
  const accept = path.startsWith("/api/") ? "application/json" : "text/markdown"
  const response = await fetch(path, {
    headers: {Accept: accept, ...client(tool)},
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

// A call that ended without an answer. Anything but a read may already have
// reached the server, so its outcome is unknown. The site never heard it, so
// the page reports it.
function unsent(entry: Entry, signal: AbortSignal | undefined): void {
  if (!entry.annotations.readOnlyHint) report({name: "tool.unsent", where: entry.name, outcome: "outcome_unknown"})
  else if (!signal?.aborted) report({name: "tool.unsent", where: entry.name, outcome: "unreachable"})
}

// The signing transport refuses with a reason such as "missing_field:title".
// The agent reads it in words; the reason itself stays in details.
function refused(code: string, operation: string | undefined, error: unknown, hint: string) {
  const reason = error instanceof Error ? error.message : String(error)
  return {ok: false, error: {code, message: explain(reason, operation), hint, details: {reason}}}
}

function explain(reason: string, operation: string | undefined): string {
  const [kind, field] = reason.split(":", 2)
  switch (kind) {
    case "missing_field": return `${field} is required.`
    case "invalid_field": return `${field} is not a field of this tool, or is not the kind of value it takes.`
    case "invalid_path_field": return `${field} must be a name, not empty.`
    case "operation_unavailable": return "No signed tool has that name. Use a name from this page's tools."
    case "operation_id_required": {
      const id = entries.find(entry => entry.name === operation)?.operation_id_field
      return `${id} is required. Use a new one for each change and keep it when retrying.`
    }
    case "body_too_large": return "The input is too large."
    case "input_complexity_exceeded": return "The input has too many parts or is nested too deeply."
    case "prepared_request_mismatch": return "The signed request is not the one prepared for this input. Prepare it again with the same input, then sign it."
    case "signed_request_required": return "Send the prepared request as request, with its proof."
    case "proof_required":
    case "invalid_proof":
    case "incomplete_proof":
    case "body_proof_required":
    case "unexpected_body_proof":
      return "The proof is missing or incomplete. Sign the prepared request with your SIWA signer and send every header it returns."
    case "untrusted_origin":
    case "insecure_origin":
      return "This page can't send signed requests."
    default: return "The input doesn't fit this tool's schema."
  }
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
      const args = input as {operation: string; input: Record<string, unknown>}
      try {
        return {ok: true, request: signedTransport().prepare(args.operation, args.input)}
      } catch (error) {
        return refused("invalid_preparation", args?.operation, error, "Check the input against the operation's schema, then prepare it again.")
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
        if (!sent) return refused("signed_call_refused", entry.name, error,
          "Nothing was sent. Prepare this exact request with prepare_agent_request, sign it with your SIWA signer, then call again with input, request and proof. If you have no signer, report that as a blocker.")
        unsent(entry, signal)
        return {ok: false, error: {code: "signed_request_failed", message: String(error),
          hint: entry.state_changing ? "Check what happened before you send it again. Keep the same idempotency_key or command_id, and sign the request again."
            : "Try again in a moment."}}
      }
    }
    const problem = inputProblem(input, entry.input_schema)
    if (problem) return {ok: false, error: {code: "invalid_input", message: problem, hint: "Fix the call, then call again."}}
    try {
      return await read(entry.name, paths[entry.name](input as Record<string, string>), signal)
    } catch (_error) {
      unsent(entry, signal)
      return signal?.aborted
        ? {ok: false, error: {code: "cancelled", message: "The read was cancelled; nothing changed.", hint: "Call again when you want it."}}
        : {ok: false, error: {code: "unreachable", message: "The page could not be read.", hint: "Try again in a moment."}}
    }
  },
}))
