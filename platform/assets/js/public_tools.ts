// The read-only tools every page offers a browser's own agent (WebMCP draft,
// document.modelContext). priv/tool_manifest.json describes each tool once;
// this file only adds the public read behind it. Nothing here signs in, writes
// or spends.

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

type Schema = {
  type: "object"
  properties: Record<string, {type: string; description: string}>
  required: string[]
  additionalProperties: false
}

type Entry = {
  name: string
  title: string
  description: string
  input_schema: Schema
  annotations: {readOnlyHint: boolean}
  scope: string
}

type Reply =
  | {ok: true; status: number; data: string}
  | {ok: false; status: number; error: {message: string}}

type Request = (signal: AbortSignal | undefined) => Promise<Reply>

// Each tool reads the site's own public document, in the Markdown an agent
// gets when it asks for that page.
const requests: Record<string, Request> = {
  about: signal => read("/about", signal),
  docs: signal => read("/docs", signal),
}

async function read(path: string, signal: AbortSignal | undefined): Promise<Reply> {
  const response = await fetch(path, {
    headers: {Accept: "text/markdown"},
    credentials: "omit",
    cache: "no-store",
    redirect: "error",
    signal,
  })
  const body = await response.text()
  if (response.ok) return {ok: true, status: response.status, data: body}
  return {ok: false, status: response.status, error: {message: body}}
}

// The browser does not check input against the schema, so each call is
// checked here, and a refusal names the field and what it must be.
function inputProblem(input: unknown, schema: Schema) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    return "Send an object of named fields."
  }
  const unknown = Object.keys(input).find(key => !Object.hasOwn(schema.properties, key))
  if (unknown) {
    const fields = Object.keys(schema.properties)
    return fields.length
      ? `${unknown} is not a field of this tool; its fields are ${fields.join(", ")}.`
      : `${unknown} is not a field of this tool; it takes none.`
  }
  const missing = schema.required.find(key => !Object.hasOwn(input, key))
  return missing ? `${missing} is required.` : null
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
    const problem = inputProblem(input, entry.input_schema)
    if (problem) return {ok: false, error: {code: "invalid_input", message: problem}}
    try {
      return await requests[entry.name](signal)
    } catch (_error) {
      return signal?.aborted
        ? {ok: false, error: {code: "cancelled", message: "The read was cancelled; nothing changed."}}
        : {ok: false, error: {code: "unreachable", message: "The page could not be read. Try again."}}
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
  window.addEventListener("pagehide", () => registration!.abort())
}
