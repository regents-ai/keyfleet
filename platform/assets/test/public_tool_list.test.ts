import {afterEach, beforeEach, expect, it, vi} from "vitest"

import manifest from "../../priv/tool_manifest.json" with {type: "json"}

const origin = "https://keyfleet.ai"

beforeEach(() => {
  vi.stubGlobal("window", {location: {origin}, setTimeout: vi.fn(), clearTimeout: vi.fn()})
  vi.stubGlobal("document", {querySelector: () => ({content: origin})})
})

afterEach(() => vi.unstubAllGlobals())

type Answer = {ok: boolean; error: {code: string; message: string; hint: string; details?: {reason: string}}}

async function call(name: string, input: unknown): Promise<Answer> {
  const {tools} = await import("../js/public_tool_list")
  return (await tools.find(tool => tool.name === name)!.execute(input, {})) as Answer
}

it("says nothing was sent when a signed tool refuses the call itself", async () => {
  const fetch = vi.fn()
  vi.stubGlobal("fetch", fetch)

  const answer = await call("mutes_add", {fleet_id: "classic-1"})

  expect(answer).toMatchObject({ok: false, error: {code: "signed_call_refused", message: "token_id is required.",
    details: {reason: "missing_field:token_id"}}})
  expect(answer.error.hint).toMatch(/^Nothing was sent\. /)
  expect(fetch).not.toHaveBeenCalled()
})

it("names the field a call lacks, and the operation's own retry field", async () => {
  const extra = await call("mutes_add", {fleet_id: "classic-1", token_id: "3", body: "x"})
  const blank = await call("rooms_post", {fleet_id: "classic-1", slug: "general", body: "hi", idempotency_key: ""})

  expect(extra.error).toMatchObject({code: "signed_call_refused", message: "body is not a field of this tool, or is not the kind of value it takes."})
  expect(blank.error).toMatchObject({code: "signed_call_refused", message: "idempotency_key is required. Use a new one for each change and keep it when retrying."})
})

it("sends nothing without an agent signer, and says how to open the site with one", async () => {
  const fetch = vi.fn()
  vi.stubGlobal("fetch", fetch)

  const answer = await call("mutes_add", {fleet_id: "classic-1", token_id: "3"})

  expect(answer.error).toMatchObject({code: "agent_auth_required", hint: expect.stringContaining("regents browser --site keyfleet")})
  expect(fetch).not.toHaveBeenCalled()
})

it("asks a change that may have been sent to be checked before it is sent again", async () => {
  const sign = vi.fn(async () => ({headers: Object.fromEntries(manifest.proof_headers.map(header => [header, "signed"]))}))
  vi.stubGlobal("regentsSign", sign)
  vi.stubGlobal("fetch", vi.fn(async () => {throw new TypeError("Failed to fetch")}))

  const answer = await call("mutes_add", {fleet_id: "classic-1", token_id: "3"})

  expect(sign).toHaveBeenCalledWith(expect.objectContaining({operation: "mutes_add", origin, method: "POST",
    path: "/api/v1/agent/fleets/classic-1/keys/3/mute"}))
  expect(answer).toMatchObject({ok: false, error: {code: "signed_request_failed"}})
  expect(answer.error.hint).toMatch(/^Check what happened before you send it again\./)
})
