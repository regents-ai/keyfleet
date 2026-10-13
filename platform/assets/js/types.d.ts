declare module "phoenix" {
  export const Socket: unknown
}

declare module "phoenix_html"

declare module "phoenix_live_view" {
  // The exact surface this application uses from phoenix_live_view 1.2.7.
  export class LiveSocket {
    constructor(path: string, socket: unknown, options: Record<string, unknown>)
    connect(): void
    getSocket(): {connect: () => void}
  }
}

declare module "phoenix-colocated/keyfleet" {
  export const hooks: Record<string, Record<string, (...args: unknown[]) => unknown>>
}

declare module "*.css"

declare module "node:fs" {
  export function readFileSync(path: URL): Uint8Array
}

declare module "node:zlib" {
  export function gzipSync(input: Uint8Array): Uint8Array
}

// The WebMCP draft's document.modelContext. Browsers without it have no such
// property; public_tools.ts checks `"modelContext" in document` before use.
type ModelContextTool = {
  name: string
  title: string
  description: string
  inputSchema: object
  annotations: object
  execute(input: unknown, client: {signal?: AbortSignal}): Promise<unknown>
}

interface ModelContext {
  registerTool(tool: ModelContextTool, options: {signal: AbortSignal}): Promise<void>
  getTools(): Promise<Array<{name: string}>>
}

interface Document {
  readonly modelContext: ModelContext
}

interface Window {
  liveSocket: import("phoenix_live_view").LiveSocket
}
