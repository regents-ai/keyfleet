import {afterEach, beforeEach, expect, it, vi} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

const origin = "https://keyfleet.ai"

beforeEach(() => {
  vi.stubGlobal("window", {location: {origin}})
  vi.stubGlobal("document", {querySelector: () => ({content: origin})})
})

afterEach(() => vi.unstubAllGlobals())

type Answer = {ok: boolean; request?: unknown; error: {code: string; message: string; hint: string; details?: {reason: string}}}

async function call(name: string, input: unknown): Promise<Answer> {
  const {tools} = await import("../js/public_tool_list")
  return (await tools.find(tool => tool.name === name)!.execute(input, {})) as Answer
}

it("says nothing was sent when a signed tool refuses the call itself", async () => {
  const fetch = vi.fn()
  vi.stubGlobal("fetch", fetch)

  const answer = await call("mutes_add", {input: {fleet_id: "classic-1"}, request: {}, proof: {}})

  expect(answer).toMatchObject({ok: false, error: {code: "signed_call_refused", message: "token_id is required.",
    details: {reason: "missing_field:token_id"}}})
  expect(answer.error.hint).toMatch(/^Nothing was sent\. /)
  expect(fetch).not.toHaveBeenCalled()
})

it("names the field a preparation lacks, and the operation's own retry field", async () => {
  const missing = await call("prepare_agent_request", {operation: "mutes_add", input: {fleet_id: "classic-1"}})
  const extra = await call("prepare_agent_request", {operation: "mutes_add", input: {fleet_id: "classic-1", token_id: "3", body: "x"}})
  const blank = await call("prepare_agent_request", {operation: "rooms_post",
    input: {fleet_id: "classic-1", slug: "general", body: "hi", idempotency_key: ""}})

  expect(missing.error).toMatchObject({code: "invalid_preparation", message: "token_id is required."})
  expect(extra.error).toMatchObject({code: "invalid_preparation", message: "body is not a field of this tool, or is not the kind of value it takes."})
  expect(blank.error).toMatchObject({code: "invalid_preparation", message: "idempotency_key is required. Use a new one for each change and keep it when retrying."})
})

it("tells an agent that signed a different request to prepare it again", async () => {
  vi.stubGlobal("fetch", vi.fn())
  const input = {fleet_id: "classic-1", token_id: "3"}
  const {request} = await call("prepare_agent_request", {operation: "mutes_add", input: {...input, token_id: "4"}})
  const proof = Object.fromEntries(manifest.proof_headers.map(header => [header, "signed"]))

  const answer = await call("mutes_add", {input, request, proof})

  expect(answer.error).toMatchObject({code: "signed_call_refused", details: {reason: "prepared_request_mismatch"}})
  expect(answer.error.message).toMatch(/^The signed request is not the one prepared for this input\./)
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
