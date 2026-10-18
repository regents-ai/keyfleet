# Controls outside this repository — 2026-10-18

The [17 Oct red-team pass](redteam-2026-10-17.md) found no exploitable in-repo
vulnerability and named three controls that live in shared libraries: the
agent sign-in binding (`siwa`), Privy token checks (`RegentPrivy`) and Credits
debits (`RegentCredits` / `RegentPoints`). This pass read each one at the exact
ref `mix.lock` pins and proved it against the real code.

- elixir-utils `695a824a7fe956a0337592b454479389cd95f8b6` (16 Oct), the pin for
  `siwa`, `regent_privy`, `regent_credits` and `regent_points`. Paths below are
  relative to that repository.
- The sign-in server, siwa-server `c08a0e55` (main, 16 Oct), runs `siwa` at its
  own pin `17141b27`; `siwa/siwa-elixir/apps/siwa/lib` is identical at both pins.
- Joken 2.7.0 and JOSE 1.11.12, as `mix.lock` pins them.

Proofs: `test/keyfleet_web/security/outside_deps_test.exs`. The sign-in tests
drive the endpoint's real `Siwa.AgentAuthPlug` and a local sign-in server that
verifies with the real `Siwa.RequestAuth` (what siwa-server runs), then name
the library's exact refusal reason. The Privy tests go through
`/auth/privy/session` with the real `RegentPrivy.Session`. The Credits tests
call `RegentCredits.hold` on this site's database.

## Verdicts

`siwa/…/siwa` is `siwa/siwa-elixir/apps/siwa/lib/siwa`.

| Control | Where it is enforced | Proof | Verdict |
|---|---|---|---|
| The signature covers method, path (with the Key's token id), receipt, key id, timestamp, wallet, chain and, with a body, its digest | `siwa/…/siwa/contract.ex:23-33`; exactly that set, no fewer and no more: `request_auth.ex:480-498`; message built from the request's own method and path: `request_auth.ex:584-598` | OD-SIWA-PATH, OD-SIWA-COMPONENTS | **Holds.** A token id in the path cannot be changed under another request's signature. |
| The site asks about the request it received, not one the caller describes | `agent_auth_plug.ex:336-355` (its own `request_path`, method, signed headers, digest of the bytes it read); repeated proof headers `:147-154`; query refused `:156-160`; partial body `:190-210` | existing `agent_join_journey_test.exs` (tampered body, query, `%61gent`) | **Holds.** |
| Single use | key = wallet, chain, audience, nonce, method, path, body digest: `request_auth.ex:610-641`, kept until the request could no longer be accepted `:603-608`; siwa-server stores it in Postgres, `lib/siwa_server/siwa/replay_store.ex:33-58` (`ON CONFLICT DO NOTHING`) | OD-SIWA-REPLAY | **Holds**, with one stated trade: siwa-server writes the row with `synchronous_commit=off` (`replay_store.ex:21-32`), so a database crash can forget the last ~600 ms of used requests and a captured one could be served once more inside its two-minute life. |
| Clock window | created within ±300 s, expiry enforced, default life 120 s: `request_auth.ex:13`, `:446-478`; `contract.ex:43`; siwa-server's tolerance `http_verifier.ex:52` (default 300) | OD-SIWA-CLOCK (three cases) | **Holds.** |
| Audience | receipt is HMAC-SHA256 under the server's secret and its `aud` must equal the site's: `receipt.ex:44-49`, `:87-88`; audience allow-list `request_auth.ex:297`; Keyfleet also requires `principal.audience == "keyfleet"`: `lib/keyfleet_web/plugs/signed_agent.ex:254-275` | OD-SIWA-AUDIENCE | **Holds** between sites. |
| Host | not covered: no `@authority` in `contract.ex:23-31` | none (no passing proof exists) | **Weak (low).** See below. |
| Privy algorithm | `privy/lib/regent_privy.ex:87` signer is ES256; Joken `Signer.verify/2` calls `JOSE.JWT.verify_strict(jwk, ["ES256"], token)` (joken `lib/joken/signer.ex:168-173`; jose `jose_jws.erl:401-420`) | OD-PRIVY-ALG-NONE, OD-PRIVY-ALG-HS256, OD-PRIVY-FORGED | **Holds.** `none` and HS256-under-the-public-key are refused. |
| Privy issuer, audience, time | `iss == "privy.io"` `regent_privy.ex:103`; `aud` equals or contains the app id `:106-114`; `exp > now` (required), `nbf <= now`, `iat <= now + 60` `:116-148` | OD-PRIVY-ISS, OD-PRIVY-AUD, OD-PRIVY-EXP, OD-PRIVY-NBF, OD-PRIVY-CONTROL | **Holds.** |
| Privy pair binding | same subject, same session id, access token carries no accounts, identity token does: `privy/lib/regent_privy/session.ex:84-98` | OD-PRIVY-PAIR | **Holds.** |
| Privy key rotation | one PEM per call from `PRIVY_VERIFICATION_KEY` (`config/runtime.exs:7-9`); no `kid`, no key fetch | none (operational) | **Holds, fails closed.** If Privy rotates its key, sign-in stops until the secret is replaced and the machine restarts. |
| Credits debit | `hold` is one transaction (`credits/lib/regent_credits/hold.ex:156-166`); locks the person's four accounts `FOR UPDATE`, sorted by id (`ledger.ex:84-95`, ash_double_entry 1.0.19 `LockForUpdate`); reads balances after the lock and refuses a shortfall (`holds.ex:20-39`, `:65-92`, `:358-362`) | OD-CREDITS-LAST, OD-CREDITS-LOCK (`--include external`) | **Holds.** The second of two debits waits for the first and is refused; the balance never goes below zero. |
| Credits idempotency | unique `(site, key)` (`hold.ex:120`, migration `20261006071031_credits_ledger.exs:119`); a repeat with the same details returns the first hold (`holds.ex:34-37`, `:335-339`); closes re-read the hold under the lock (`holds.ex:264-283`) | OD-CREDITS-KEY | **Holds.** |
| Points | no person or agent can debit Points: awards and corrections are system-only (`points/lib/regent_points/entry.ex:109`), serialized by an account lock (`store.ex:17-21`, `award.ex:18`, `reverse.ex:12`), unique `(program_id, award_key)` (`entry.ex:119`), cap rows locked and updated atomically with a non-negative check (`store.ex:94`, `cap_usage.ex:15-16`, `:48-49`). Keyfleet earns nothing yet (`config/config.exs:48-49`) | none: unreachable from this site, and its fixtures need the shared people table | **Holds** by code. |

Keyfleet itself places and closes no Credits holds: its code only reads
balances and history and reports purchases (`lib/keyfleet_web/components/credits_panel.ex`,
`lib/keyfleet_web/controllers/agent_account_controller.ex`). Every site writes
the one shared ledger with these same locks.

## The one weak control: the host is not signed

What binds a signed agent request to Keyfleet is the receipt's audience,
`keyfleet`. Four hosts verify under that audience through the same sign-in
server: keyfleet.ai, keyfleet-staging (`fly.staging.toml:10` uses
`https://siwa.regents.sh`, and the audience is fixed in `signed_agent.ex:222`),
`regents-club.notebooks.keyfleet.ai` and `code.keyfleet.ai` (siwa-server
`fly.toml:19`).

**Exploit path.** Whoever receives an agent's signed request before it reaches
the sign-in server can send it, unchanged, to another `keyfleet` host within
its two-minute life; the first host to ask the sign-in server spends it. That
receiver is a misdirected agent's destination (an agent told by a poisoned
prompt that Keyfleet's API lives at some other address) or a compromised
staging or notebook host. The method, path, body and nonce cannot be changed,
so the attacker can only make the exact request the agent signed happen on
another `keyfleet` host, for example a test action meant for staging landing on
production. It cannot act as another Key or another agent.

**Fix (in elixir-utils and siwa-server, not here).** Add `@authority` to the
covered components in `Siwa.Contract` (a contract version 2), have
`Siwa.AgentAuthPlug.http_verify_payload/3` send `conn.host`, and have the
verifier build the component from it. Until then, a separate audience for
staging (`keyfleet-staging` in siwa-server's `SIWA_WALLET_ORIGINS` and
Keyfleet's audience read from config instead of the literal) closes the
staging-to-production case.

## Two notes for later

- Keyfleet never asks for read leases (`signed_agent.ex:219-224` passes no
  `read_only`), so the in-memory per-machine single-use record
  (`request_auth/replay_store.ex`) is not on its path. If a route ever turns
  leases on while the site runs on more than one machine, a leased read could be
  served once on each machine within its life.
- Privy `exp` has no leeway. A machine clock running ahead refuses fresh
  tokens; it never admits stale ones.

## Running it

```sh
cd platform
mix test test/keyfleet_web/security/outside_deps_test.exs
mix test test/keyfleet_web/security/outside_deps_test.exs --include external
SOBELOW_HOME=_build/sobelow mix sobelow --config --exit
mix hex.audit
load/local.sh zap
```

The second line adds OD-CREDITS-LOCK, which races holds on separate
connections and leaves its committed rows in the test database. The ZAP kit,
`platform/load/zap-baseline.sh` with `platform/load/zap-rules.tsv`, refuses
keyfleet.ai, its subdomains and the production Fly app.
