import {afterEach, beforeEach, expect, it, vi} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

const origin = "https://keyfleet.ai"

beforeEach(() => {
  vi.stubGlobal("window", {location: {origin}})
  vi.stubGlobal("document", {querySelector: () => ({content: origin})})
})

afterEach(() => vi.unstubAllGlobals())

type Answer = {ok: boolean; request?: unknown; error: {code: string; message: string; hint: string}}

async function call(name: string, input: unknown): Promise<Answer> {
  const {tools} = await import("../js/public_tool_list")
  return (await tools.find(tool => tool.name === name)!.execute(input, {})) as Answer
}

it("says nothing was sent when a signed tool refuses the call itself", async () => {
  const fetch = vi.fn()
  vi.stubGlobal("fetch", fetch)

  const answer = await call("mutes_add", {input: {fleet_id: "classic-1"}, request: {}, proof: {}})

  expect(answer).toMatchObject({ok: false, error: {code: "signed_call_refused", message: "Error: missing_field:token_id"}})
  expect(answer.error.hint).toMatch(/^Nothing was sent\. /)
  expect(fetch).not.toHaveBeenCalled()
})

it("asks a change that may have been sent to be checked before it is sent again", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => {throw new TypeError("Failed to fetch")}))
  const input = {fleet_id: "classic-1", token_id: "3"}
  const {request} = await call("prepare_agent_request", {operation: "mutes_add", input})
  const proof = Object.fromEntries(manifest.proof_headers.map(header => [header, "signed"]))

  const answer = await call("mutes_add", {input, request, proof})

  expect(answer).toMatchObject({ok: false, error: {code: "signed_request_failed"}})
  expect(answer.error.hint).toMatch(/^Check what happened before you send it again\./)
})
