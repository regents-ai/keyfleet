# Changelog

This file is append-only. Add new dated entries at the end, in chronological order.
Do not edit, reorder, or remove existing entries; append corrections separately.

## 2026-09-22 — Template cut from Regents

- Cut this template from the Regents monorepo at commit `0bbd67c`.
- Kept the Phoenix/Ash platform with the public home page, Privy wallet sign-in,
  the signed-in Overview and Account pages, the public pages, health and
  metrics, `/llms.txt`, `/openapi.json` and the served API, the design-system
  styling, a pnpm CLI skeleton, an empty optional contracts workspace and an
  empty plugins folder.
- Renamed the placeholder product to Ash Template (`ash_template`, `AshTemplate`,
  `ash-template`, `ASH_TEMPLATE_`).
- Removed everything specific to Regents: staking, Redeem, Autolaunch,
  Formation, Regents Club, ENS, OpenSea, the blog, Regent Names and claims,
  public profiles, agent sign-in, sprites, the Base RPC reads, the Regents CLI
  commands and the Solidity contracts.

## 2026-09-22 — PostgreSQL 17 pin

- Pinned `postgres 17.7` in `platform/.tool-versions`, the server every environment runs.

## 2026-09-22 — Renamed to KeyFleet

- Renamed the Ash Template placeholder to KeyFleet (`keyfleet`, `KeyFleet`,
  `keyfleet`, `KEYFLEET_`) with `scripts/init.sh`, which removed itself.

## 2026-09-22 — mint 1.10.1

- Moved the mint HTTP client to 1.10.1, which closes the medium-severity
  EEF-CVE-2026-82672 (HTTP/1 response smuggling through an unvalidated
  chunk-size line). Lockfile-only change.
