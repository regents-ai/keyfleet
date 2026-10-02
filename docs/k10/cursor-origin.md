# K10 capability check: Cursor Origin inside KeyFleet

Checked 2 October 2026; probes ran 16:43–16:50 UTC. This was research plus probes that needed no login: no account, no credentials, no money, no repo edits.

**Verdict: works with caveats.** Origin can host one repository per fleet, let any current key-holder's agent push to it with plain git, and tell KeyFleet about every push. None of that needs a Cursor account per agent: KeyFleet hands out short-lived write passes from its own app. The caveats:
- Origin sees every agent as KeyFleet.
- Taking access away can lag by up to 5 minutes.
- Creating repositories needs a person logged in to Cursor.
- The product is a beta that changes almost daily.
- Cursor's terms may not allow handing write access to outside agents; that needs a question to Cursor.

## 0. What "Cursor Origin" is
The name is not ambiguous. It is **Origin, Cursor's (Anysphere's) Git hosting service**, which Cursor calls "a git forge for the agentic era". It was announced on 17 August 2026 ([changelog](https://cursor.com/changelog/origin-code-hosting)) and covered by [DevOps.com](https://devops.com/cursor-launches-origin-code-hosting-platform-as-github-rival/), [DigitalOcean](https://www.digitalocean.com/resources/articles/cursor-origin-vs-github) and [Flavio Copes](https://flaviocopes.com/cursor-origin/). No other product uses the name. cursor-origin.dev and learncursor.dev are third-party explainer sites.

How KeyFleet planned to use it:
- KEYFLEET_ACTIVEGRAPH_ADDENDUM.md §13.1: "Origin/Git remain authoritative for repository contents and commits".
- §13.6 rules out automatic Origin merge or deployment, and keeps Origin credentials off the graph host.
- ethereum-shards-plan.md lists "Restricting marimo, Cursor Origin and ddocs" as open.
- The site's tech_stack.ex carries the promise line.

So KeyFleet imagined Origin holding the code, ActiveGraph holding the work state, and the chain deciding who is a member. Origin fits that split.

## 1. What Origin is today
- **Status:** early beta. Available on the Start, Pro, Pro+, Ultra, Teams and Enterprise plans; not on the free plan. "Access opens in stages."
- **Namespace:** each team or person claims a codebase name (`cursor.com/codebase/{owner}`). It cannot be changed during the beta.
- **Visibility:** repositories are Internal or Private only. There are no public repositories.
- **Git:** HTTPS at `https://origin.cursor.com/{owner}/{repo}.git`. SSH also answers (banner `SSH-2.0-CursorOrigin`) for SSH keys registered to a user, or for certificates from a team's own certificate authority.
- **Command-line tool:** `origin`, a closed-source binary for macOS and Linux (glibc only). It covers login (browser or `--api-key`), repo create/list/clone/delete, pull requests, rulesets, SSH keys, and `api` for raw API calls.
- **REST API:** `https://api.cursor.com/v1/origin`, "Early Beta and subject to change". There is an OpenAPI 3.1 spec with 113 operations and a Markdown reference.
- **API churn:** 29 changes marked "Breaking" between 5 August and 1 October. On 29 September, for example, the access-control endpoints moved to new paths and the old ones were removed.
- **AI-tool server:** `api.origin.cursor.com/mcp`. It accepts app tokens, but the docs say it is "currently available only in Cursor and Grok Bot".

**Ways to sign in:**
- **Browser login or personal API key:** represents a Cursor user. The CLI swaps the key for a short-lived token.
- **SSH key:** represents a Cursor user.
- **SSH certificate from a team's own certificate authority:** represents members of the owning team.
- **Origin App:** works like a GitHub App. The app signs a request with its Ed25519 key and gets an installation access token (`oit_…`). That token works for the REST API and for git over HTTPS (username `x-access-token`). It lasts **at most 15 minutes, and never longer than the app's request**.
- **Installation user token:** the app acts for one Cursor user, who must be a member of the namespace.
- **Service accounts:** Enterprise plan only.

There is no separate agent identity in Origin. To Origin, an agent is either a Cursor user or an app.

## 2. Repository per fleet, write access for current key-holders
**Creating repositories.** The app's API cannot create them: that needs a user's login (`namespace:repositories:create`). The docs say: "Namespace-wide repository listing and repository creation are not part of the partner API." With four fleets, Sean creates them once by hand or with `origin repo create`.

**Way A, recommended: KeyFleet hands out passes from its own app.**
1. Sean creates one internal app and installs it with permission to push (`contents:write`) and to open pull requests (`pull_requests:write`).
2. An agent signs in to KeyFleet with SIWA. The existing `Keyfleet.Graph.Checks.KeyActor` check confirms the agent holds the key, or a shard of it, today; ownership is fresh; and the key's edits are not restricted.
3. KeyFleet then asks Origin for a token limited to that one fleet's repository (`repositoryIds: [fleet_repo]`), with about 5 minutes of life.
4. The agent pushes with plain git.
5. **Taking access away:** once the key changes hands, KeyFleet issues no new pass. A pass already handed out expires within 5 minutes (15 at most). A single pass cannot be cancelled early. Deleting the whole installation stops every pass immediately, but for every fleet at once. The addendum already accepts that off-chain checks lag the chain.

**Way B: each key-holder is a Cursor user, and KeyFleet grants and removes access.** Rejected. Origin's access API can add and remove access, but "Users must belong to the owner's organization". That means a paid seat in Regent's team ($40/month each), and Cursor accounts for every agent.

**Branches and pull requests.** Agents can push branches with git. Through the API they can also create branches, commit files without git, open pull requests and comment on them, and post check results.
- Branch protection rules can guard `main` and let named users, teams or apps skip them. But every agent's pass *is* the KeyFleet app, so a rule cannot tell agents apart.
- With push permission an agent can technically merge a pull request, which the addendum forbids. If that matters, protect `main` or leave pull-request permission out of the pass.

**Notifications for the fleet page.** Origin sends signed notifications for pushes, pull requests opened, merged and closed, comments, reviews and checks.
- A push notification lists each changed branch with its old and new commit and whether history was rewritten. It includes the newest commit's message, author and time, and who pushed. Pushes made with a pass show the pusher as the KeyFleet app.
- It does not include the full list of commits; a separate "list commits" call fills that in.
- Each notification is sent at least once, retried 7 times over about 16 minutes, and can be re-requested for 7 days.
- The signature scheme is Origin's own, so standard webhook libraries can't check it. I checked it in a few lines of plain Elixir.
- It fits KeyFleet's usual pattern: receive, hand to a background job, update the page live.

**Who pushed.** To Origin, every push is "the KeyFleet app". KeyFleet records each pass it hands out (agent, key, ownership epoch, expiry). Agents can put their key in the commit author, but that is self-declared. If two agents in a fleet hold passes at the same time, KeyFleet cannot prove which one made a given push.

## 3. Cursor's cloud agents, and other agents
- Cursor's own cloud agents and Automations can clone, push and open pull requests on Origin. They run under a Cursor account and bill it. KeyFleet does not need them.
- Hermes, Dots, Muse and Grok can use plain git over HTTPS with a pass, or the REST API with the pass as a Bearer token. Neither needs Cursor's command-line tool.
- Whether a non-Cursor tool can use Origin's AI-tool server with a pass is not verified.
- Grok Bot appears to be a Cursor product. A key-holder's Grok Bot would still need a KeyFleet pass, unless that person is in Regent's Cursor team.

## 4. Costs, limits, terms
- **Money:** pushes only work if the namespace owner is on a paid plan. Likely options: an Individual plan at $20/month (if an internal app can live in a personal namespace, which is unverified) or Teams with one seat at $40/month. No separate Origin or storage price is published.
- **Rate limits:** 3,000 points a minute per installation, shared across all fleets; 6,000 for the app itself; 600 per user. Reads cost 1 point, writes 5, creating a repository 10. Git has its own limit, size not published. Cursor can raise limits for "design partners".
- **Terms (updated 3 September 2026):**
  - Nothing specific about bot accounts.
  - The account holder is responsible for "all activities that occur under your account".
  - §1.5(iii) forbids to "rent, lease, lend, or sell the Service". That is the reason to ask Cursor before handing passes to outside agents.
  - §1.6: beta services are provided "without any warranty, support, maintenance, or storage" and can be discontinued at any time. Keep a copy of each fleet's repository elsewhere.

## 5. Probes (no account)
Everything is in `/private/tmp/claude-501/-Users-sean-Documents-regent/666c051b-939c-459a-9137-0ff1800e0e86/scratchpad/k10-origin/`: the saved docs and full API spec in `docs/`, raw output in `probes/probe-log.txt` and `probes/origin_probe.out`.

1. Origin's public sign-in description (`/.well-known/openid-configuration`): answered normally, as documented.
2. Origin's public signing keys (`/keys`): three live Ed25519 keys, cached for 10 minutes.
3. API calls with no login (rate limit, get repository): refused with "missing valid authentication credentials".
4. `git ls-remote` with no login: refused; the reply says to run `origin auth login`.
5. Git with a fake pass (`x-access-token:oit_bogus`): "your access token was not accepted". So logging in with a pass as the git password is the live path.
6. Origin's AI-tool server with no login: refused with "Missing Bearer token".
7. SSH check (`ssh-keyscan`): port 22 open, banner `SSH-2.0-CursorOrigin`.
8. I read Cursor's install script without running it. The tool is a closed-source binary, macOS and glibc Linux only, and a new build came out today.
9. Local Elixir script (`probes/origin_probe.exs`) using only built-in crypto: built and checked an app sign-in token; checked Origin's notification signature (a good one accepted, a tampered one refused); decoded Origin's three live signing keys (32 bytes each).
10. Sent that throwaway sign-in token to Origin once: refused because the app doesn't exist, which shows the server reads the token as documented.

**Not checked without an account:**
- whether Origin is open on Sean's plan yet;
- whether internal apps work in a personal namespace;
- whether an app installed on "all repositories" also covers repositories made later;
- the size of git's rate limit;
- a real push, and a real notification arriving;
- whether non-Cursor tools can use Origin's AI-tool server;
- repository size limits.

KeyFleet's server image uses Debian, so the CLI would run there if ever needed. Way A doesn't need it: KeyFleet already has the libraries for signing tokens and making HTTP calls (`jose`, `joken`, `req`).

## 6. Smallest honest end-to-end slice
**"Each fleet gets one Origin repository. Any current key-holder's agent (owner or shard) can get a 5-minute write pass from KeyFleet and push with plain git. The fleet page lists recent pushes live."**

**What Sean has to do** (about an hour, $20–40 a month):
1. Get a paid Cursor plan with Origin. Teams with one seat is the safe choice. Check that `cursor.com/codebase` shows **Get Started**, since access opens in stages.
2. Claim the namespace. This is permanent during the beta; suggestion: `keyfleet`.
3. Create the four fleet repositories as Private.
4. Create the internal app at `cursor.com/codebase/settings/apps`:
   - register the public half of an Ed25519 key;
   - set the notification address to `https://keyfleet.ai/origin/webhooks` and subscribe to push events;
   - install it on the four repositories with push and pull-request permission.
5. Put the app's ID, installation ID and private key into Fly secrets.
6. Optional: email hi@cursor.com about the "lend" clause and a higher rate limit.

**What KeyFleet has to build** (about 3–5 days):
- A record linking each fleet to its Origin repository.
- An action that issues a pass, using the existing KeyActor check. It returns the clone address, the pass and its expiry, and records who got it. The pass itself is never stored. Agents reach it the same ways they reach other KeyFleet tools.
- A notification receiver: check the signature, ignore duplicates, hand off to a background job, save each push, and update the fleet page's "Recent code" list live.
- A paragraph in the agent guide on getting a pass and pushing.
- Tests: someone without the key gets no pass; a transferred key gets no new pass; a bad signature is refused; a duplicate notification is ignored.
- A nightly copy of each fleet repository somewhere else.

**Risks:**
1. Fast-changing beta: expect at least one breaking change in a 3-week window.
2. Staged access could block everything.
3. Up to 5 minutes' lag when a key changes hands.
4. Origin sees one app, so who pushed is only in KeyFleet's records.
5. No public repositories; visitors see code only through KeyFleet.
6. New fleets need Sean to create their repository.
7. The terms question, and one shared rate limit for all fleets.

**If Origin can't be used:**
- A GitHub App works the same way, so KeyFleet's code barely changes. But the site's "Cursor Origin" line would no longer be true and would need rewording.
- Mirroring a GitHub repository into Origin doesn't help: Origin's API treats mirrors as read-only, so agents would still push to GitHub.
- Self-hosting Forgejo on Fly has the same wording problem, plus more to run.

**Verdict: works with caveats.** Every needed piece is documented and the endpoints answer. The caveats are product and business risks, not missing features. The first real proof is Sean turning Origin on and creating the app.

**Sources:**
- Origin docs: [overview](https://cursor.com/docs/origin), [git](https://cursor.com/docs/origin/git), [creating repositories](https://cursor.com/docs/origin/create-repository), [command-line tool](https://cursor.com/docs/origin/cli), [settings](https://cursor.com/docs/origin/settings), [integrations](https://cursor.com/docs/origin/integrations)
- Origin API: [index](https://cursor.com/docs/api/origin/llms.txt), [full reference](https://cursor.com/docs/api/origin/llms-full.txt), [spec](https://cursor.com/docs/api/origin/openapi.yaml), [changelog](https://cursor.com/docs/api/origin/changelog.md), [access grants](https://cursor.com/docs/api/origin/grants-api.md), [acting for users](https://cursor.com/docs/api/origin/acting-as-users.md), [AI-tool server](https://cursor.com/docs/api/origin/mcp.md)
- [Announcement](https://cursor.com/changelog/origin-code-hosting), [pricing](https://cursor.com/pricing), [team pricing](https://cursor.com/docs/account/teams/pricing.md), [service accounts](https://cursor.com/docs/account/enterprise/service-accounts.md), [terms](https://cursor.com/terms-of-service)
- Press: [DevOps.com](https://devops.com/cursor-launches-origin-code-hosting-platform-as-github-rival/), [DigitalOcean](https://www.digitalocean.com/resources/articles/cursor-origin-vs-github), [Flavio Copes](https://flaviocopes.com/cursor-origin/)
