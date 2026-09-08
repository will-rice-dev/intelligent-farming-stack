# CLAUDE.md — intelligent-farming-stack

Guidance for AI coding agents (Claude Code, Copilot, etc.) and human contributors. Read this before generating or committing code. Standard across all Intelligent Farming Foundation repositories.

## What this repo is
A one-command docker-compose bench that boots ChirpStack (US915), Leftenant, and a standalone
device-event store together, auto-provisions an "Intelligent Farming" tenant + API key, and
wires everything so a fresh device runs `docker compose up` and is ready. Device events are
stored by ChirpStack's own PostgreSQL integration into `events-postgres` (it auto-creates the
`event_*` tables); `events-api` (PostGraphile) serves read-only GraphQL over them. Leftenant runs an
image the setup scripts build from its public repo (`github.com/intelligent-farming/leftenant`, main)
with `docker build <giturl>` — not compose's `build:` git context, which breaks on Windows
(docker/compose#13815). No sibling clone needed, and this stack does not depend on
`intelligent-farming-hub`.

An opt-in `farm` profile adds the normalized telemetry path beside that: `farm-postgres`
(the `farmdata` database), a `farmdata-migrate` one-shot, `telemetry-bridge` (MQTT consumer +
inventory reconciler + curation API), and `farmdata-api` (read-only GraphQL). It runs beside the
event store rather than replacing it — that archives ChirpStack's event shape, this holds
per-metric readings against a shared vocabulary — and neither reads the other.

## Images built elsewhere (the second exception, alongside Leftenant)
Three of the four `farm` services run images built in the **telemetry-bridge** repo
(`npm run images:build`) and consumed here **by tag from the local image store**. Do not add a
`build:` context pointing at a sibling checkout, and do not use a git-URL context — the Windows bug
above rules the second out, and this repo's "no sibling clone needed" promise rules out the first.
`farm-api/` is the exception that proves the rule: it is built here because it lives here.

## Project & licensing (non-negotiable)
- Licensed GNU AGPL-3.0-or-later. The full text is in LICENSE at the repo root — never modify, move, or remove it.
- Copyright holder is Intelligent Farming Foundation.
- Outbound = inbound: all contributions are made under AGPL-3.0-or-later. Do not relicense, dual-license, or add a different license. Commercial/dual licensing is handled only by counsel.

## Every source file: add this header (adjust comment syntax to the language)
```
SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (C) 2026 Intelligent Farming Foundation
```
Do not paste the full license into source files — the header points to LICENSE. Keep the copyright line as "Intelligent Farming Foundation" (not an individual).

## Every commit: sign off (DCO)
- Sign off every commit with `git commit -s`.
- CI rejects commits without the Signed-off-by line. Agents creating commits must include it.

## Dependencies (license compatibility)
- OK to include: MIT, BSD-2/3-Clause, Apache-2.0, ISC, MPL-2.0, GPL-3.0, LGPL-3.0, AGPL-3.0.
- Do NOT add: GPL-2.0-only, proprietary/closed, or non-commercial/source-available licenses (BSL, SSPL, Commons Clause, Elastic License).
- Vendored code keeps its license/attribution, recorded in NOTICE. The ChirpStack config under `chirpstack/`, `mosquitto/`, `gateway-bridge/`, `postgresql/` is MIT (chirpstack-docker) — see NOTICE. If unsure, stop and flag it.

## AGPL section 13 (network/SaaS)
- If this software runs as a network service, users interacting over the network must be offered its complete source. Build in a way to get the source (e.g., a "Source" link to this repo).

## Commercial use / relicensing (route to counsel — do not act)
- Any commercial license, dual-licensing, CLA, or relicensing is handled only by the Foundation's IP counsel. Do not add commercial terms, exceptions, or additional permissions.

## Bench-only posture (do not ship as-is)
- `mosquitto.conf` allows anonymous MQTT; ChirpStack admin defaults to admin/admin; the API
  secret default is a placeholder; the event API/DB (`events-api`/`events-postgres`) bind to
  loopback. These are bench defaults. Anything network-exposed needs real auth, TLS, and a
  rotated `CHIRPSTACK_API_SECRET`. Exposing `events-postgres` for Fivetran is opt-in via
  `EVENTS_POSTGRES_HOST_BIND` + `EVENTS_POSTGRES_WAL_LEVEL` — see the README.
- The `farm` profile adds more of the same: the **curation API writes and has no auth and no TLS**
  (loopback-bound for that reason; its `Origin` refusal is not a substitute for auth), `farmdata`
  ships placeholder passwords for the owner and all three minted logins, and `farmdata-api` exposes
  every reading to anyone who can reach it with GraphiQL on by default.
- **Login users are minted at deploy time, never by a migration.** `farmdata`'s service roles are
  NOLOGIN group roles — privilege carriers, not accounts — so that a frozen, hash-locked committed
  migration never holds a password. `farmdata-migrate` creates the accounts from the environment
  and grants each membership in exactly one role. Add a consumer there, not with a hand-written
  `CREATE ROLE`. What membership cannot carry is **ownership**, which is why `partman_maintainer`
  owns the two partition sets outright and partition maintenance gets a login pair of its own:
  `ATTACH`/`DROP PARTITION` require owning the parent, and no `GRANT` confers that.

## Per-PR checklist
- New files have the SPDX + copyright header
- Commits signed off (`git commit -s`)
- No incompatible-licensed dependencies added
- Third-party code keeps its license/attribution (recorded in NOTICE)
- Network-facing changes preserve the section 13 "offer source" path
- No commercial/relicensing terms added (counsel's job)
