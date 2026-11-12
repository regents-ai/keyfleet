import {randomUUID} from "node:crypto"
import {expect, test, type Page} from "@playwright/test"
import {type Answer, callSigned, installModelContext, newAgent, pairAgent} from "./support/agent_tools"
import {installAuthenticatedPrivy} from "./support/authenticated_privy"
import {call, prepareFleet, pushCode, sellKey} from "./support/fleet_chain"

// A fleet's members work on one goal together, the way they do on the site:
// one member's agent takes over the fleet's General project, sets the goal
// and its task, writes a notebook, runs it, sends the code and submits the
// task; another member's agent joins the goal, runs the same notebook again
// and accepts the work. The members read each step on the workspace's pages.
// The fleet's work graph runs here with its own Python host, and its
// notebooks answer from a stand-in hub (`Keyfleet.BrowserWorkspace`).
const fleet = "fleet_tech_accelerant"
const fleetPath = "/accelerant/1"
// Every fleet's first project, archived until a Key takes it over.
const general = "general"
// Signed in as "valid" and as "other-account" (test/support/test_privy_verifier.ex).
const maker = "0x1111111111111111111111111111111111111111"
const reviewer = "0x3333333333333333333333333333333333333333"

test.describe.configure({mode: "serial"})

let makerKey: number
let reviewerKey: number
let makerAgent: string
let reviewerAgent: string
const made: {goal?: string; task?: string; notebook?: string; result?: string; commit?: string} = {}

test.beforeAll(() => {
  prepareFleet(fleet)
  call("start!", [fleet], "Keyfleet.BrowserWorkspace")
  makerKey = sellKey(fleet, maker)
  reviewerKey = sellKey(fleet, reviewer)
  makerAgent = newAgent()
  reviewerAgent = newAgent()
  pairAgent(makerAgent, maker)
  pairAgent(reviewerAgent, reviewer)
})

test.beforeEach(async ({page}) => {
  await installModelContext(page)
})

async function open(page: Page, path: string) {
  await page.goto(path)
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  await expect(page.locator("html")).toHaveAttribute("data-webmcp-status", "connected")
}

// Calls a signed tool and expects it to succeed; answers its data.
async function ok(page: Page, agent: string, tool: string, input: Record<string, unknown>) {
  const answer: Answer = await callSigned(page, agent, tool, input)
  expect(answer.ok, `${tool}: ${JSON.stringify(answer)}`).toBe(true)
  return answer.data
}

const write = (asKey: number, fields: Record<string, unknown>) => ({
  fleet_id: fleet,
  as_key: asKey,
  command_id: randomUUID(),
  ...fields,
})

test("one member's agent sets a goal and its task, writes and runs a notebook, sends code and submits", async ({page}) => {
  await open(page, fleetPath)
  await ok(page, makerAgent, "agents_join", {name: "Maker agent", declared_harness: "test"})
  await ok(page, makerAgent, "projects_take_over", {fleet_id: fleet, project: general, as_key: makerKey})

  const goal = await ok(page, makerAgent, "workspace_create", write(makerKey, {
    project: general,
    type: "goal",
    data: {title: "Count the harbour's boats", outcome: "A notebook that counts them, run twice."},
  }))
  made.goal = goal.result.id

  const task = await ok(page, makerAgent, "workspace_create", write(makerKey, {
    project: general,
    type: "task",
    data: {title: "Write the counting notebook"},
  }))
  made.task = task.result.id
  await ok(page, makerAgent, "workspace_join", write(makerKey, {id: made.task}))
  await ok(page, makerAgent, "workspace_link", write(makerKey, {source: made.task, target: made.goal, type: "implements"}))

  const notebook = await ok(page, makerAgent, "notebooks_create", {
    fleet_id: fleet,
    project: general,
    title: "Boat count",
    code: "import marimo\napp = marimo.App()\n",
    description: "Counts the boats in the harbour.",
    goal: made.goal,
    idempotency_key: randomUUID(),
  })
  made.notebook = notebook.notebook_id
  expect(notebook.notebook_url).toContain(made.notebook)
  await ok(page, makerAgent, "notebooks_add_file", {
    fleet_id: fleet,
    project: general,
    notebook_id: made.notebook,
    path: "boats.csv",
    content: "name\nKestrel\nWren\n",
  })

  const run = await ok(page, makerAgent, "notebooks_run", {fleet_id: fleet, project: general, notebook_id: made.notebook, idempotency_key: randomUUID()})
  const result = await ok(page, makerAgent, "notebooks_result", {fleet_id: fleet, project: general, notebook_id: made.notebook, run_id: run.run_id})
  expect(result.status).toBe("succeeded")
  made.result = result.result_url
  expect(made.result).toBeTruthy()

  pushCode(fleet, makerKey, maker, "a".repeat(40))
  const pushes = await ok(page, makerAgent, "code_pushes", {fleet_id: fleet, project: general})
  made.commit = pushes.pushes[0].commit_url
  expect(made.commit).toBeTruthy()

  const evidence = await ok(page, makerAgent, "workspace_create", write(makerKey, {
    project: general,
    type: "evidence",
    data: {title: "The notebook's count", source_uri: made.result},
  }))
  const read = await ok(page, makerAgent, "workspace_show", {fleet_id: fleet, id: made.task})
  const patched = await ok(page, makerAgent, "workspace_edit", write(makerKey, {
    id: made.task,
    expected_version: read.object.version,
    set: {commit_ref: made.commit, notebook_ref: notebook.notebook_url, reviewer_key: reviewerKey},
  }))
  await ok(page, makerAgent, "workspace_submit_task", write(makerKey, {
    id: made.task,
    expected_version: patched.result.version,
    result_ref: made.result,
    evidence: [evidence.result.id],
  }))
})

test("another member's agent joins the goal, runs the notebook again and accepts the work", async ({page}) => {
  await open(page, fleetPath)
  await ok(page, reviewerAgent, "agents_join", {name: "Reviewer agent", declared_harness: "test"})
  await ok(page, reviewerAgent, "workspace_join", write(reviewerKey, {id: made.goal}))

  const listed = await ok(page, reviewerAgent, "notebooks_list", {fleet_id: fleet, project: general})
  expect(listed.notebooks.map((notebook: {notebook_id: string}) => notebook.notebook_id)).toContain(made.notebook)
  const file = await ok(page, reviewerAgent, "notebooks_read_file", {fleet_id: fleet, project: general, notebook_id: made.notebook, path: "boats.csv"})
  expect(file.content).toContain("Kestrel")

  const run = await ok(page, reviewerAgent, "notebooks_run", {fleet_id: fleet, project: general, notebook_id: made.notebook, idempotency_key: randomUUID()})
  const again = await ok(page, reviewerAgent, "notebooks_result", {fleet_id: fleet, project: general, notebook_id: made.notebook, run_id: run.run_id})
  expect(again.status).toBe("succeeded")

  // The other member's sync lists the task among those it may review.
  const synced = await ok(page, reviewerAgent, "fleets_sync", {
    fleet_id: fleet,
    rooms: [],
    graph: {after_seq: 0},
    proposals: {after_seq: 0},
    run: {kind: "session"},
  })
  expect(synced.yours.reviews.map((waiting: {id: string}) => waiting.id)).toContain(made.task)

  const task = await ok(page, reviewerAgent, "workspace_show", {fleet_id: fleet, id: made.task})
  await ok(page, reviewerAgent, "workspace_review_task", write(reviewerKey, {
    task: made.task,
    task_version: task.object.version,
    decision: "accept",
    rationale: "Ran the notebook again and got the same count.",
    conflicts_of_interest: "none",
    reproduction: "passed",
  }))
})

test("the members read the goal, its notebook, its code and the accepted task on the workspace's pages", async ({page}) => {
  await (await installAuthenticatedPrivy(page, "valid")).establishLocalSession()

  await open(page, `${fleetPath}/workspace`)
  const project = page.locator("#workspace-place-project")
  await expect(project).toContainText("Count the harbour's boats")
  await expect(project).toContainText("Write the counting notebook")
  // Accepted, the task no longer waits in Reviews.
  await expect(page.locator("#workspace-reviews")).toBeVisible()
  await expect(page.locator("#workspace-review-rows > li")).toHaveCount(0)

  await open(page, `${fleetPath}/workspace?place=docs`)
  await expect(page.locator("#workspace-place-docs")).toContainText("Boat count")

  await open(page, `${fleetPath}/workspace?place=code&project=general`)
  await expect(page.locator("#code-pushes > li")).toHaveCount(1)

  await open(page, call("item_path", [fleet, made.task!]))
  const item = page.locator("[data-phx-main]")
  await expect(item).toContainText("Write the counting notebook")
  await expect(item).toContainText(/accepted/i)

  await open(page, call("item_path", [fleet, made.goal!]))
  await expect(page.locator("#workspace-goal-map-items")).toContainText("Write the counting notebook")
  await expect(page.locator(`#workspace-goal-notebook-rows [data-notebook="${made.notebook}"]`)).toContainText("Boat count")
  await expect(page.locator(`#workspace-goal-notebook-rows a[href="${made.result}"]`).first()).toBeVisible()
  await expect(page.locator("#workspace-goal-code-rows [data-commit]")).toHaveCount(1)
})
