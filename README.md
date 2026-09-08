# intelligent-farming-stack

Docker Compose bench that runs ChirpStack (US915), Leftenant, and a standalone device-event store
as one stack. On `up`, a one-shot provisioner creates an "Intelligent Farming" ChirpStack tenant,
mints a tenant API key, and writes it where Leftenant and the codec tooling read it. Leftenant
starts already configured.

Device events are stored by **ChirpStack's built-in PostgreSQL integration**: ChirpStack writes
every event (uplinks, joins, acks, status, …) straight into a standalone Postgres (`events-postgres`),
auto-creating its `event_*` tables on first boot. **`events-api`** (PostGraphile) serves a read-only
GraphQL/GraphiQL endpoint over them. There is no separate collector, and nothing here depends on the
`intelligent-farming-hub` repo.

**`leadsman`** watches that store on a cron and raises alerts — dead devices, flat batteries, codecs
that stopped decoding, thresholds you set. It is plain SQL, so monitoring the whole fleet costs
nothing per reading, and the alerts it produces are what an agent or notifier consumes instead of raw
telemetry. See [Alerting](#alerting-leadsman).

**Get started:** one command [installs & runs](#install--run) the whole stack (no Git, no config),
one command [updates](#updating) it, and the [command reference](#command-reference) covers day-to-day
operations. Jump to [Prerequisites](#prerequisites) first.

## Prerequisites

- Docker + Docker Compose v2 (with network access on first build — Leftenant is built from its
  public repo, and the other images are pulled from Docker Hub). No sibling repos need to be cloned.

## Install & run

The only prerequisite is a running Docker daemon (see [Prerequisites](#prerequisites)). The
one-command installers below download the repo and run the bundled setup script, which builds
Leftenant from its public repo, pulls the other images, and starts + provisions the whole stack — no
Git, and no `.env`, needed. Every setting has a built-in default; copy `.env.example` to `.env` only
if you want to change one.

### Windows — one command

Open **PowerShell** and paste this single line. It downloads the repo to
`%USERPROFILE%\ifs\intelligent-farming-stack-main` (no Git needed) and runs the setup script:

```powershell
$ErrorActionPreference='Stop'; iwr 'https://github.com/intelligent-farming/intelligent-farming-stack/archive/refs/heads/main.zip' -OutFile "$env:TEMP\ifs.zip"; Expand-Archive "$env:TEMP\ifs.zip" "$env:USERPROFILE\ifs" -Force; Set-Location "$env:USERPROFILE\ifs\intelligent-farming-stack-main"; powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

### macOS / Linux — one command

Paste this single line into a terminal. It downloads and extracts the repo into
`intelligent-farming-stack-main/` under your current directory (no Git needed — just `curl`) and runs
the setup script:

```sh
curl -fsSL https://github.com/intelligent-farming/intelligent-farming-stack/archive/refs/heads/main.tar.gz | tar -xz && cd intelligent-farming-stack-main && bash setup.sh
```

Prefer Git? `git clone https://github.com/intelligent-farming/intelligent-farming-stack.git && cd
intelligent-farming-stack && bash setup.sh` (or `.\setup.ps1`) does the same.

> **Why the setup script and not just `docker compose up`?** Leftenant is built from its public repo
> with `docker build <giturl>`, which the script runs before `docker compose up`. Compose's own
> git-URL build context is [broken on Windows](https://github.com/docker/compose/issues/13815) (it
> throws *"the filename, directory name, or volume label syntax is incorrect"*), so the build is done
> with the buildx CLI — which clones the repo server-side and works on every platform.

### Then open

- Leftenant (pre-configured): http://localhost:4173
- ChirpStack admin UI: http://localhost:8080 (default login `admin` / `admin`)
- ChirpStack REST API: http://localhost:8090
- Device-event GraphQL (PostGraphile): http://localhost:5050/graphql — GraphiQL IDE at http://localhost:5050/graphiql

With the [farm profile](#farm-telemetry-store--graphql-farm-profile) running, two more:

- Farm telemetry GraphQL: http://localhost:5051/graphql — GraphiQL IDE at http://localhost:5051/graphiql
- Curation API: http://localhost:8092 — **no authentication, no TLS**; loopback only

The first run builds Leftenant from its public repo and pulls the ChirpStack/Postgres/etc. images, so
it needs network access and takes a few minutes. The setup script waits for the one-shot provisioner
and prints these URLs; you can also check it with `docker compose logs provisioner`.

## Updating

Pull the latest of everything — the repo files, the published images, and Leftenant's latest `main` —
then recreate the containers. **Your data is preserved**: the compose project name is pinned, so the
named volumes (`eventsdata`, `chirpstack-pgdata`, …) are reused across updates regardless of where the
repo lives. A `.env` you created is also left untouched (it isn't part of the download).

### Windows — one command

```powershell
$ErrorActionPreference='Stop'; iwr 'https://github.com/intelligent-farming/intelligent-farming-stack/archive/refs/heads/main.zip' -OutFile "$env:TEMP\ifs.zip"; Expand-Archive "$env:TEMP\ifs.zip" "$env:USERPROFILE\ifs" -Force; Set-Location "$env:USERPROFILE\ifs\intelligent-farming-stack-main"; powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Update
```

### macOS / Linux — one command

```sh
curl -fsSL https://github.com/intelligent-farming/intelligent-farming-stack/archive/refs/heads/main.tar.gz | tar -xz && cd intelligent-farming-stack-main && bash setup.sh --update
```

Already have the repo on disk? Just run the helper from the repo folder — `./setup.sh --update`
(or `powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Update`). It rebuilds Leftenant from the
latest `main` (`docker build --pull <giturl>`), pulls newer ChirpStack/Postgres images, and recreates
the containers. If you ever suspect a stale Leftenant build, force it with `./setup.sh --rebuild`
(`-Rebuild`), which adds `--no-cache`.

## Stopping and removing

Run these from the repo folder (`%USERPROFILE%\ifs\intelligent-farming-stack-main` on Windows, or
wherever you extracted/cloned it):

```sh
docker compose stop        # pause containers, keep everything
docker compose down        # stop + remove containers/network, KEEP data volumes
docker compose down -v     # stop + remove containers AND delete all data (full reset)
```

The helper scripts wrap the last two: `./setup.sh --down` / `-Down` (keep data) and
`./setup.sh --reset` / `-Reset` (wipe data). To uninstall completely, run `docker compose down -v`
and then delete the repo folder.

## Command reference

Once installed, all day-to-day commands run from the repo folder. **Prefer the helper scripts** —
they also build/refresh the Leftenant image, which Compose does not (see the note below). The raw
`docker compose` forms are equivalent *once the Leftenant image exists*.

| Task | Helper script | `docker compose` (Leftenant image must already exist) |
|------|---------------|--------------------------------------------------------|
| Start | `./setup.sh` · `.\setup.ps1` | `docker compose up -d --build` |
| Update (latest Leftenant + images, keep data) | `./setup.sh --update` · `.\setup.ps1 -Update` | rebuild Leftenant (see note), then `docker compose pull --ignore-pull-failures && docker compose build --pull && docker compose up -d` |
| Clean rebuild (no cache) | `./setup.sh --rebuild` · `.\setup.ps1 -Rebuild` | `docker compose build --no-cache && docker compose up -d` |
| Stop, keep data | `./setup.sh --down` · `.\setup.ps1 -Down` | `docker compose down` |
| Stop, wipe data | `./setup.sh --reset` · `.\setup.ps1 -Reset` | `docker compose down -v` |
| Follow logs | — | `docker compose logs -f` |
| List available alert checks | — | `docker compose run --rm leadsman list` |
| Validate the alert config | — | `docker compose run --rm leadsman verify` |
| Run checks now, write nothing | — | `docker compose run --rm leadsman run --dry-run` |
| Apply an edited alert config | — | `docker compose restart leadsman` |

> **Two files the scripts create for you.** `.env` (from `.env.example`) and
> `leadsman/leadsman.json` (from `leadsman/leadsman.example.json`). Both are git-ignored, so your
> settings and your choice of alert checks survive an update. If you run raw `docker compose`, create
> them first — `leadsman` exits with a config error if its file is missing:
> ```sh
> cp .env.example .env
> cp leadsman/leadsman.example.json leadsman/leadsman.json
> ```

> **Leftenant image.** Leftenant has no `build:` section in compose — its image is built from the
> public repo with the buildx CLI (compose's git-URL build context is broken on Windows). The helper
> scripts do this automatically. If you use the raw `docker compose` commands, build/refresh the image
> yourself first:
> ```sh
> docker build --pull -t intelligent-farming-stack/leftenant:local https://github.com/intelligent-farming/leftenant.git#main
> ```

For the **first install** and for a **full update that also refreshes the repo files**, use the
one-command installers under [Install & run](#install--run) and [Updating](#updating).

## What gets provisioned

The `provisioner` service (`provisioning/provision.py`) logs in to the ChirpStack REST API,
ensures the tenant named by `TENANT_NAME` exists, mints an API key named `API_KEY_NAME`, and
writes to the shared `shared` volume:

| File | Consumer |
|------|----------|
| `config.json` | Leftenant reads it at startup and seeds its settings (skips the first-run wizard) |
| `leftenant.env` | same values as an env file |
| `leftenant-connection.txt` | the codec attach step (`attach-codecs.py`) — REST URL / API key / Tenant UUID |

Re-running `docker compose up` is idempotent: the existing tenant is reused, and the API key is
reused from `config.json` rather than re-minted. Resetting the `shared` volume forces a new key.

## Data flow

```
gateway --(Semtech UDP :1700)--> gateway-bridge --> mosquitto(:1883) --> chirpstack
                                                                             |
                              ChirpStack integrations (both enabled) ────────┤
                                                                             |
   PostgreSQL integration (durable store) ───────┐        MQTT integration ──┘
                                                  v                          v
                              events-postgres <--(writes event_* rows)   mosquitto
                                   |    ^                                     |
                                   |    └──(writes leadsman.alert)── leadsman  |
                                   |                                     |    |
                                   |                     (POST per new alert) |
                                   |                                     v    |
                        events-api (PostGraphile, GraphQL :5050)   notify.destinations
                                   |                               (SMS / Telegram /
                       reads public.event_* AND leadsman.open_alert  Signal / Hermes)

Leftenant (browser :4173) --(REST :8090, CORS)--> chirpstack-rest-api --> chirpstack
```

ChirpStack keeps its MQTT integration (Leftenant's browser join monitor subscribes to it) **and**
adds the PostgreSQL integration, which is the durable store `events-api` reads from.

With the `farm` profile, a second consumer subscribes to the same MQTT integration and writes
normalized readings instead of raw events:

```
   MQTT integration (qos 1) --> mosquitto --> telemetry-bridge --> farm-postgres (farmdata)
                                                   |                     |
                    (REST :8090) chirpstack-rest-api                farmdata-api
                        inventory reconciler                   (PostGraphile, GraphQL :5051)
                                                   |
                              operator --> curation API :8092 (place a device on a property)
```

The two stores answer different questions and neither reads the other: `events-postgres` archives
ChirpStack's own event shape verbatim, while `farmdata` holds per-metric readings with a shared
vocabulary, so two sensors from different vendors land as interchangeable data.

## Ports

| Port | Service | Notes |
|------|---------|-------|
| 4173 | leftenant | provisioning UI (pre-configured) |
| 8080 | chirpstack | admin UI + gRPC |
| 8090 | chirpstack-rest-api | REST API (Leftenant); CORS allow-origin = `LEFTENANT_ORIGIN` |
| 1883 | mosquitto | native MQTT |
| 9001 | mosquitto | MQTT over websockets |
| 1700/udp | chirpstack-gateway-bridge | Semtech UDP packet-forwarder gateways |
| 3001 | chirpstack-gateway-bridge-basicstation | BasicStation gateways (LNS WebSocket) |
| 5050 | events-api | GraphQL (loopback by default; 5000 avoided — macOS AirPlay) |
| 5434 | events-postgres | host-side psql/export; loopback by default — `EVENTS_POSTGRES_HOST_BIND` to expose (see below) |
| — | leadsman | publishes **no** port. It only talks to `events-postgres`; alerts are read via `events-api` or POSTed outbound |
| 5051 | farmdata-api | *(farm profile)* GraphQL over the telemetry store; loopback by default |
| 5436 | farm-postgres | *(farm profile)* host-side psql; loopback by default |
| 8092 | telemetry-bridge | *(farm profile)* curation API — **no auth, no TLS**; loopback by default |

## Device event store & GraphQL

ChirpStack's PostgreSQL integration (configured in `chirpstack/chirpstack.toml`) connects to
`events-postgres` as the owner role and, on first boot, runs its own migrations to create these
tables in the `public` schema of the `chirpstack_events` database:

| Table | Event |
|-------|-------|
| `event_up` | uplinks — decoded payload in `object` (jsonb), plus `rx_info` / `tx_info`, `dev_eui`, `f_cnt`, `f_port`, `dr`, … |
| `event_join` | OTAA joins (`dev_addr` assigned) |
| `event_ack` | downlink acknowledgements |
| `event_tx_ack` | downlink transmission acks (per gateway) |
| `event_status` | device status (battery, margin) |
| `event_location` | resolved device location |
| `event_log` | device-level log events |
| `event_integration` | events emitted by other integrations |

`events-api` (PostGraphile) introspects that schema and exposes it as GraphQL. It connects as the
read-only `events_api` role (`SELECT` on `public` only — created by
`postgresql/events-initdb/010_events_roles.sh`), with default mutations disabled, so the endpoint is
read-only by construction and enforced at the DB.

```graphql
# most recent uplinks with their decoded payload
{
  allEventUps(orderBy: TIME_DESC, first: 20) {
    nodes { devEui deviceName time fCnt fPort object }
  }
}
```

`POST http://localhost:5050/graphql` for queries; the GraphiQL IDE is at
`http://localhost:5050/graphiql` (`EVENTS_API_GRAPHIQL=false` disables it).

ChirpStack's `event_*` tables ship only a primary-key index, so `events-api` runs with
`ignoreIndexes: true` — that's what makes `orderBy: TIME_DESC` and `condition: { devEui: … }`
available on every column. `leadsman-migrate` adds the indexes those filters actually need
(`event_up (time)`, `event_up (dev_eui, time)`, and the same on `event_join` / `event_status`) as part
of the default boot, so this is no longer only safe at bench volumes — see
`LEADSMAN_APPLY_EVENT_INDEXES` if you'd rather leave ChirpStack's tables untouched.

> First boot ordering is handled for you: a one-shot `events-schema-wait` blocks `events-api` until
> ChirpStack has created `event_up`, so the GraphQL schema is populated on the first `up` (no manual
> restart). Send one device uplink (or trigger a join) to see rows.

## Alerting (Leadsman)

`leadsman` is a scheduled rule engine over the same event store. Every 15 minutes it runs the checks
you enabled, and maintains alerts in a `leadsman` schema in the same database. It is the piece that
turns "we are recording telemetry" into "we are told when something is wrong".

Two things make it worth running by default:

- **It costs nothing per reading.** The checks are SQL. Watching a hundred devices for the rest of the
  season is the same handful of queries every 15 minutes, whether or not anything is wrong.
- **It catches silence.** A device that stops transmitting emits no event to react to. Only something
  that periodically asks "who hasn't reported?" finds it — `device-silent` is the check no purely
  event-driven pipeline can replace.

### What runs by default

Fourteen checks, out of a menu of 64. These need no crop-specific tuning, and they cover the
failures that otherwise make every other check silently blind.

Eight are about a device:

| Check | Catches |
|-------|---------|
| `device-silent` | a device that stopped reporting altogether |
| `battery-low` | decoded battery / supply voltage below threshold, with hysteresis |
| `decode-failure` | uplinks arriving but the codec producing nothing — including a JSON `null` payload |
| `soil-moisture-missing` | a field that used to decode and silently vanished (usually a codec or profile change) |
| `device-log-error` | ChirpStack's own device-level error events |
| `status-battery-low` | MAC-layer battery percentage from `DevStatusAns` — works with no codec at all |
| `status-margin-low` | demodulation margin collapsing, i.e. a link about to fail |
| `join-churn` | a device re-joining repeatedly instead of holding its session |

Six are about the layers underneath one — the gateway, the site, the box itself. These matter
because a fault down there does not present as itself: when a gateway stops forwarding, every
device behind it goes silent at once, so a device-only monitor reports a dozen faults that each
name a working sensor and none that names the gateway.

| Check | Catches |
|-------|---------|
| `fleet-silent` | nothing arriving from **anything** — one site alert instead of one per device, and minutes rather than hours after the fact |
| `gateway-silent` | one gateway of several stopped forwarding, while the rest kept going |
| `gateway-deaf` | a gateway online and sending stats while receiving nothing — dead concentrator, antenna off its mount, water in the feeder |
| `gateway-never-seen` | registered in ChirpStack and never connected: the commissioning mistake |
| `host-restarted` | this box rebooted, and how long nothing was being monitored |
| `host-address-changed` | the host's LAN address moved, so every gateway is still forwarding to an address nobody is listening on |

That last one is worth knowing about before you need it. A gateway never rediscovers its network
server — it is told an address once and forwards there forever. Come back from a power cut on a new
DHCP lease and the whole site goes dark while every gateway, ChirpStack, and this stack all report
themselves perfectly healthy. `host-address-changed` names the old and new address so the fix is
"re-point the gateways" rather than an afternoon of investigation. It reads `gatewayBridgeHost` from
the provisioner's `/shared/config.json`, which is the same value the Add-Gateway wizard hands out,
so it needs no configuration here.

**Also worth setting: `LEADSMAN_HEARTBEAT_URL`.** While this box is off, Leadsman is off, so
nothing above can report an outage *while it is happening* — a six-hour power cut produces no
alerts at all and looks exactly like a quiet night. A heartbeat inverts that: the engine pings an
external receiver after every sounding, and that receiver alarms when the pings stop. It has to
live somewhere the outage cannot reach, so a watchdog on this same device does not count. See
`.env.example`.

The remaining 50 are mostly thresholds over the normalized codec vocabulary — wind speed, air and
soil temperature, leaf wetness, tank level, CO₂, pressure, rainfall rate, geofence breach, and so on
— plus three gateway checks that need site-specific tuning (`gateway-flapping`,
`gateway-redundancy-lost`, `gateway-time-unsynced`). They ship **disabled**, because a sensible
threshold depends on your crop, region, and equipment, and enabling everything at once produces
noise rather than signal.

### Noise control

One thing is on by default that withholds alerts, so it is worth stating plainly: while a
`fleet-silent` or `gateway-silent` alert is open, `device-silent` alerts are **recorded but not
delivered**. That is the storm not happening — a gateway outage would otherwise send one message per
orphaned device, each naming a sensor that is fine.

Nothing is lost. Suppressed alerts appear in `leadsman status` and `leadsman.open_alert` with
`detail.suppressedBy` naming what withheld them, and any still open when the outage alert resolves
are delivered then — so a node that really is dead is still reported once the gateway is back. Put
`"suppress": []` in `leadsman/leadsman.json` to deliver everything regardless of cause.

### Choosing checks

Everything is in **`leadsman/leadsman.json`**, mounted read-only into the container. The setup
scripts create it from `leadsman.example.json` on first run and it is **git-ignored** — the same
arrangement as `.env`, so your check selection is not clobbered when you update the repo. Flip
`"enabled": true` on the entries you want, then:

```sh
docker compose run --rm leadsman verify     # parse the config, confirm each check's tables/columns exist
docker compose restart leadsman
```

`verify` is worth running before the restart: it catches a typo'd path or a check whose table is
missing *now*, rather than at 3am in a sounding. To see every available check and its parameters:

```sh
docker compose run --rm leadsman list
docker compose run --rm leadsman run --dry-run    # run every enabled check, write nothing
```

The same check can be enabled more than once with different parameters — give each instance its own
`"as"` name (that name is the alert `kind`, so they don't collide).

### Reading alerts

The `leadsman` schema is exposed over the **same read-only GraphQL endpoint** as the telemetry, so
there are no new credentials and no new port:

```graphql
# everything currently wrong with the fleet
{
  allOpenAlerts(orderBy: RAISED_AT_DESC) {
    nodes { devEui deviceName kind severity summary raisedAt detail }
  }
}
```

`open_alert` is a view of alerts with no `resolved_at`. Alerts have a lifecycle rather than being
fire-and-forget: a check that keeps matching **holds the existing alert open** instead of raising a
duplicate, and the alert resolves when the condition clears. A flapping sensor produces one alert, not
ninety-six a day. (A check that *errors* resolves nothing — failure to look is not evidence of health.)

Or straight from Postgres:

```sh
docker compose exec events-postgres \
  psql -U events -d chirpstack_events -c 'SELECT * FROM leadsman.open_alert ORDER BY raised_at DESC'
```

### Getting alerts delivered

Leadsman delivers each **newly raised** alert exactly once and stamps it delivered on success; a
failure leaves it pending so a later sounding retries. A destination is either a messaging platform
(`twilio`, `telegram`, `signal` — a one-line text to a phone) or a `webhook` (the alert JSON, signed),
which is what a **Hermes** route wants.

Hermes is deployed separately from this stack. Add a destination for it in
`leadsman/leadsman.json`, then point it and its secret from `.env`:

```jsonc
// leadsman/leadsman.json
"notify": {
  "destinations": {
    "agent": { "webhookUrl": "http://host.docker.internal:8644/hermes/agent", "webhookAuth": "hmac" }
  },
  "routing": { "situation": "agent" }
}
```

```sh
# .env — overrides the URL above, so the address lives with every other address
LEADSMAN_DEST_AGENT_WEBHOOK_URL=http://host.docker.internal:8644/hermes/agent
LEADSMAN_WEBHOOK_TOKEN=<the same secret the Hermes route expects>

docker compose up -d leadsman
```

Routing `situation` alone sends Hermes only the alerts that need interpreting; `fact` alerts
stay recorded, or go to a Twilio/Telegram/Signal destination for a text message. `hmac` signs
`<unix-seconds>.<body>` with HMAC-SHA256, which is replay-safe and what Hermes' generic
webhook route verifies.

`hmac` sends `X-Webhook-Signature-V2` (HMAC-SHA256 of `<unix-seconds>.<body>`) plus
`X-Webhook-Timestamp`, which is what Hermes' generic webhook route verifies — the timestamp is inside
the signed string, so a captured request can't be replayed. `host.docker.internal` reaches a Hermes
running on the Docker host rather than inside this compose network. `token` and `bearer` modes are
also supported for other receivers.

For routine threshold alerts, point it at a Hermes route with **`deliver_only: true`** — that
forwards to SMS without invoking the model, so alert volume costs no tokens. Reserve agent-invoking
routes for the alerts that genuinely need interpretation. An agent that instead polls telemetry on a
schedule spends tokens on every run whether or not anything is wrong, which is the cost this
arrangement exists to avoid.

### Privileges

`leadsman` connects as its own role (`POSTGRES_LEADSMAN_USER`, created by
`postgresql/events-initdb/020_leadsman_role.sh`): `SELECT` on `public`, `INSERT`/`UPDATE` on the
`leadsman` schema. No DDL, no `DELETE`, nothing that can alter or destroy ChirpStack's data. Schema
creation is a separate one-shot (`leadsman-migrate`) that runs as the owner role, so the long-running
container never holds DDL rights.

To run the stack **without** Leadsman, clear `POSTGRES_LEADSMAN_USER` / `POSTGRES_LEADSMAN_PASSWORD`,
set `EVENTS_API_SCHEMAS=public`, and remove the `leadsman` / `leadsman-migrate` services along with
`events-api`'s `depends_on` entry for the latter.

## Farm telemetry store & GraphQL (`farm` profile)

The event store above keeps ChirpStack's own event shape. The **farm telemetry store** keeps the
same uplinks decoded into narrow per-metric readings against a shared vocabulary — so a soil probe
from one vendor and a soil probe from another land as interchangeable data — each stamped with the
property the device was on when it measured. Four services, all opt-in:

| Service | What it does |
|---------|--------------|
| `farm-postgres` | `postgres:18` + pg_partman + PostGIS, holding the `farmdata` database |
| `farmdata-migrate` | One-shot: applies the migration chain, mints the login users, loads the property projections |
| `telemetry-bridge` | Consumes ChirpStack's MQTT events, mirrors its device list, serves the curation API |
| `farmdata-api` | Read-only GraphQL over the `registry` and `telemetry` schemas |

### Build the images first

**They are not published anywhere yet.** Three of the four are built in the
[telemetry-bridge](https://github.com/intelligent-farming/telemetry-bridge) repository and consumed
here by tag from your local Docker image store — this stack never builds from a sibling checkout.
In a telemetry-bridge checkout:

```sh
npm install
npm run images:build     # farm-postgres, telemetry-bridge, farmdata-migrate
```

Skip that and `up` fails with `pull access denied for intelligent-farming/farm-postgres`.

### Run it

```sh
docker compose --profile farm up -d
docker compose --profile farm logs -f telemetry-bridge

# tearing down needs the profile too, or these are left running:
docker compose --profile farm down
```

`farmdata-migrate` runs to completion and stays `Exited (0)`; compose re-runs it on every `up`,
which is intended — every step is idempotent, so a second run applies no migrations and rewrites
the same rows. If the bridge or the API report *"dependency failed to start"*, that one-shot is
where to look: `docker compose logs farmdata-migrate`.

### Querying it

```sh
curl -s http://localhost:5051/graphql -H 'content-type: application/json' \
  -d '{"query":"{ allReadingLatests(first: 5) { nodes { deviceId metric valueNum measuredAt } } }"}'
```

GraphiQL is at http://localhost:5051/graphiql (`FARM_API_GRAPHIQL=false` turns it off) and works
because it is served from this same origin. A browser page served from anywhere *else* gets a 403:
this API answers no cross-origin request, by design (see the security notes). `curl` and
server-side clients send no `Origin` and are unaffected.

The useful entry points:

- **`allReadings`** — every per-metric reading. The table is partitioned by month; the API exposes
  the parent as one table and hides the partitions, so this is the whole history.
- **`allReadingLatests`** — the newest reading per device/metric/channel. What a dashboard wants.
- **`allSoilMonitorVs`, `allSoilMonitorLatestVs`, …** — one pair of pivot views per device category
  (37 of them), turning the narrow rows sideways into a column per metric. Generated from the codec
  vocabulary, so they change only when it does.
- **`allDevices`, `allProperties`, `allDeviceAssignments`** — the registry: what exists, where it
  is, and the history of where it has been.

`sync` is deliberately not exposed — it holds export watermarks and replication bookkeeping, which
belong to the services rather than to a client.

### Curating devices

A device that reports before anyone has placed it is still ingested — readings are never gated on
curation — and lands on the seeded default property, flagged as needing attention. The curation API
is how a person corrects that:

```sh
# what nobody has placed yet
curl -s 'http://localhost:8092/v1/devices?needsCuration=true'

# place one (actor is who is doing it; a machine actor name is refused)
curl -s -X POST http://localhost:8092/v1/devices/<device-id>/assignment \
  -H 'content-type: application/json' \
  -d '{"propertyId":"<property-id>","actor":"you@example.com"}'
```

Re-sending an identical request answers `changed: false` rather than writing again. `GET /` lists
every verb.

**Two things to know before pointing anything at it.** It serves no authentication and no TLS in
this release, which is why it is published on loopback only. And any request carrying an `Origin`
header is refused with 403 — deliberately, since there is no auth to protect a browser caller with
— so this is a `curl`/CLI surface, not one to call from a web page.

### Where the values come from

`farm/projection.json` is the bench's organization and property, and it has exactly one job beyond
seeding: `FARM_BRIDGE_PROPERTY_ID` is left blank in `.env` and derived from this file's
`default_property_id`, so the property the seeder writes and the property the bridge uses cannot
drift apart. Point at a real property by editing this file, not by pasting a UUID in two places.

The ChirpStack API key the inventory reconciler uses is read from `/shared/config.json` — minted by
the provisioner at run time, so no environment variable can carry it. That is the same file
Leftenant reads.

### Partition maintenance

`reading` and `ingest_event` are partitioned monthly with retention, and **nothing on this bench
runs maintenance automatically** — the pg_partman background worker is preloaded but deliberately
left unpointed, since aiming it at a database before the chain has installed pg_partman makes it
fail every cycle. Premake covers the near term. To run it by hand:

```sh
docker compose exec farm-postgres psql -U farmdata_owner -d farmdata \
  -c "SELECT partman.run_maintenance()"
```

## Region / sub-band

The active band is a single flag, **`REGION`** in `.env` (default `us915_0` — US915 channels 0-7).
It drives everything that has to agree on the band: ChirpStack's `enabled_regions`, both gateway
bridges' MQTT topic prefix, and the BasicStation channel-plan file. Change it and recreate:

```sh
# .env
REGION=us915_1        # US915 channels 8-15

docker compose up -d      # recreates the affected services
```

`us915_0` and `us915_1` ship ready to use. To run **any other band**, add its two config files, then
set `REGION` to that id:

- `chirpstack/region_<id>.toml` — the ChirpStack region file (its `id` and `topic_prefix` must equal
  `<id>`); region files for every band are in the upstream chirpstack-docker project.
- `gateway-bridge/chirpstack-gateway-bridge-basicstation-<id>.toml` — only if you use BasicStation
  gateways (Semtech UDP gateways need no per-band file).

> All gateway RF settings (frequencies, sub-band) come from `REGION`; only one band is enabled at a
> time. An 8-channel US915 gateway is configured for one sub-band — match `REGION` to it.

## Connecting a gateway

Register the gateway in ChirpStack (via Leftenant or the admin UI) under the provisioned tenant, with
its **Gateway EUI**. Make sure the gateway's sub-band matches the [`REGION`](#region--sub-band) flag
(default `us915_0`). Then point the gateway's packet forwarder at this host — the stack runs a bridge
for **both** gateway protocols, both tagged with the `REGION` topic prefix so ChirpStack handles them
identically:

| Gateway protocol | Point it at | Host port to allow |
|------------------|-------------|--------------------|
| **Semtech UDP** packet forwarder (legacy `global_conf.json`) | `<this-host-ip>` : **1700**, UDP | UDP 1700 |
| **BasicStation** (LNS) | LNS/`tc` URI `ws://<this-host-ip>:3001` | TCP 3001 |

`<this-host-ip>` is the machine's LAN IP (`ipconfig` on Windows, `ip addr` / `ifconfig` on
macOS/Linux) — not `localhost`, and not the address of any previous server the gateway used.

Windows notes:
- Allow the relevant inbound port through Windows Firewall (admin PowerShell) — UDP 1700 for Semtech,
  or TCP 3001 for BasicStation:
  ```powershell
  New-NetFirewallRule -DisplayName "LoRa BasicStation 3001" -Direction Inbound -Protocol TCP -LocalPort 3001 -Action Allow
  ```
- BasicStation on this bench uses plain `ws://` (no TLS); set the gateway's LNS URI accordingly and,
  if it defaults to CUPS, either disable CUPS or have it fall back to the LNS URI.

Verify frames are arriving, in order of the data path:

```sh
docker compose logs -f chirpstack-gateway-bridge-basicstation   # BasicStation: expect the gateway to connect
docker compose logs -f chirpstack-gateway-bridge                 # Semtech UDP: expect periodic stats
docker compose exec mosquitto mosquitto_sub -t "+/gateway/#" -v   # frames on the broker (any REGION)
```

If the bridge log shows the gateway but ChirpStack still reads "never seen", the registered Gateway
EUI doesn't match what the gateway reports.

## Mock data (demo & end-to-end tests)

No gateway or sensors? The bundled [`mock-sensors`](./mock-sensors) harness simulates a fleet of 23
real ag sensors — a wire-format spread (Dragino, Milesight, Decentlab, including a multilayer soil
profile probe) plus the first-deployment hardware (SenseCAP S2120 and the whole Makerfabs AgroSense
line) — and injects **valid**
LoRaWAN uplinks (correct MIC + encrypted payload) via the Semtech UDP gateway bridge, exactly like a
real packet-forwarder gateway. The mocked readings therefore flow through the whole pipeline — gateway
bridge → ChirpStack decode → `event_up` (Postgres) **and** the MQTT application stream — so you can see
the stack working end-to-end. It provisions its own gateway/application/device-profiles/devices
(idempotent) and attaches each sensor's normalized codec to its profile, so decoded values show up
regardless of the optional [`CODECS_DIR`](#codecs-optional) attach path below.

The harness is **US915-only** — it derives uplink RF parameters for `us915_0`/`us915_1` and throws on
any other [`REGION`](#region--sub-band), so a non-US915 bench gets no mock data.

Run the continuous demo generator (stack already up):

```sh
docker compose --profile mock up -d --build mock-sensors     # opt-in; never runs by default
docker compose --profile mock logs -f mock-sensors
```

Watch it populate GraphiQL (http://localhost:5050/graphiql), the ChirpStack UI, or Leftenant. Tune the
cadence with `MOCK_INTERVAL_SECONDS` (default 15). Stop it with
`docker compose --profile mock stop mock-sensors` (the `mock` profile has to be named for compose to
see the service at all).

Run the end-to-end test (boots the stack if needed, then tears down only what it started):

```sh
bash scripts/e2e.sh
```

It provisions the mock devices, sends every known payload of every sensor, and asserts each decoded
`object` lands on MQTT **and** in `event_up`. The script runs on the host, so it reads this repo's `.env` (the
same file compose reads) and points the suite at the ports, credentials and `REGION` configured there
rather than at hardcoded localhost defaults. It also **stops the `mock-sensors` demo service** for the
run — the demo loop emits from the same DevEUIs and would otherwise race the assertions — and leaves
it stopped. See [`mock-sensors/README.md`](./mock-sensors/README.md) for standalone usage and
configuration.

## Codecs (optional)

If codec `.js` files are present at `CODECS_DIR` (default `./codecs`), the provisioner runs
`attach-codecs.py` against the new tenant key, so ChirpStack decodes payloads into the `object`
column of `event_up`. Point `CODECS_DIR` at another folder (e.g. `../intelligent-farming-hub/codecs`)
to reuse a codec set from elsewhere; an empty/missing dir just makes this a no-op. Device profiles
must already exist for codecs to bind, so on a first boot (before Leftenant creates profiles) this is
typically a no-op — re-run `docker compose up` (or `docker compose run --rm provisioner`) after
provisioning profiles. The codec `.js` files are Makerfabs-derived and git-ignored.

## LAN access

The defaults assume the browser reaches the bench at `localhost`. To reach it by IP, set
`LEFTENANT_ORIGIN`, `LEFTENANT_CHIRPSTACK_URL`, and `LEFTENANT_MQTT_URL` in `.env` to the device's
address (e.g. `http://192.168.1.50:4173`, `http://192.168.1.50:8090`, `ws://192.168.1.50:9001`),
then recreate: `docker compose up -d`.

## Fivetran / off-device sync

`events-postgres` holds the device events (the `event_*` tables in the `public` schema of the
`chirpstack_events` DB). By default it binds to `127.0.0.1` and runs `wal_level=replica`, so nothing
off the edge device can reach it. To let Fivetran (or any log-based CDC / logical-replication
consumer) pull from it, do the following. All of it is opt-in through `.env` — leaving the values at
their defaults keeps the loopback-only bench posture.

Sync as the read-only replication role below, not `events` (the owner). The `chirpstack-postgres` DB
is LoRaWAN network state, not device events — don't sync it.

### 1. Expose the Postgres port

```sh
# .env
EVENTS_POSTGRES_HOST_BIND=0.0.0.0     # or a specific LAN/VPN address the connector uses
```

Bind to the narrowest address that works (a VPN or private-LAN IP over `0.0.0.0`), and
put a firewall in front scoped to the consumer's source addresses. Fivetran Cloud
connects from a fixed set of published IPs; a **Fivetran Hybrid Deployment / local
agent** is preferable on a farm edge box — the agent dials out, so Postgres never has
to listen on a public interface (bind it to the agent's network only).

### 2. Enable logical WAL (for log-based CDC)

Fivetran's log-based connector reads the write-ahead log, which requires
`wal_level=logical`. Skip this step if you use Fivetran's key-based sync instead
(the `event_*` tables have monotonic keys / a `time` column to poll on).

```sh
# .env
EVENTS_POSTGRES_WAL_LEVEL=logical
```

`wal_level` is a startup parameter, so recreate the container to apply it:

```sh
docker compose up -d events-postgres
docker compose exec events-postgres psql -U events -d chirpstack_events -c "SHOW wal_level;"   # -> logical
```

`max_wal_senders` / `max_replication_slots` default to 10 (PG16), which is enough for
one Fivetran slot; raise `EVENTS_POSTGRES_MAX_*` in `.env` only if you add more consumers.

### 3. Create the read-only replication role + publication

Set both credentials in `.env` (a blank user or password skips role creation entirely):

```sh
# .env
EVENTS_POSTGRES_FIVETRAN_USER=fivetran
EVENTS_POSTGRES_FIVETRAN_PASSWORD=$(openssl rand -base64 24)   # paste the generated value
EVENTS_POSTGRES_FIVETRAN_PUBLICATION=fivetran_pub              # default
```

`postgresql/events-initdb/010_events_roles.sh` creates a `LOGIN REPLICATION` role with `SELECT` on
`public` (nothing else) and a publication scoped to the `public` schema — which auto-includes the
`event_*` tables ChirpStack creates. It runs automatically on a **fresh** `eventsdata` volume. On an
**existing** volume, run it by hand after setting the env (idempotent — safe to re-run, and re-syncs
the password after a rotation):

```sh
docker compose up -d events-postgres    # so the container has the new POSTGRES_FIVETRAN_* env
docker compose exec events-postgres bash /docker-entrypoint-initdb.d/010_events_roles.sh
```

Verify:

```sh
docker compose exec events-postgres psql -U events -d chirpstack_events \
  -c "\du fivetran" -c "SELECT pubname FROM pg_publication;"
```

### 4. Configure the Fivetran connector

Point Fivetran's **PostgreSQL** source at the device:

| Field | Value |
|-------|-------|
| Host / Port | the device address / `5434` (or your `EVENTS_POSTGRES_HOST_PORT`) |
| Database | `chirpstack_events` (`EVENTS_POSTGRES_DB`) |
| User / Password | `EVENTS_POSTGRES_FIVETRAN_USER` / `EVENTS_POSTGRES_FIVETRAN_PASSWORD` |
| Update method | Logical replication (WAL) |
| Publication | `fivetran_pub` (`EVENTS_POSTGRES_FIVETRAN_PUBLICATION`) |
| Replication slot | Fivetran creates it (the role has `REPLICATION`); e.g. `fivetran_slot` |
| Schema | `public` |

Notes:
- **TLS.** The bench Postgres has no TLS. Terminate it in front (VPN, an `stunnel`/proxy
  sidecar, or the Fivetran local agent's tunnel) before any non-loopback exposure.
- **Deletes/updates.** Events are append-only, so inserts replicate cleanly. Each `event_*` table
  has a primary key (default replica identity), so any update/delete would replicate too.
- **Slot disk use.** An offline/paused connector leaves its replication slot holding WAL,
  which grows `eventsdata`. If you retire the connector, drop the slot:
  `SELECT pg_drop_replication_slot('fivetran_slot');`.
- **Extra table.** The schema-scoped publication also includes ChirpStack's
  `__diesel_schema_migrations` bookkeeping table, so it will appear at the destination.
  Harmless — exclude it in Fivetran's table selector if you don't want it synced.

## Security posture

Bench defaults only: anonymous MQTT, ChirpStack `admin`/`admin`, placeholder `CHIRPSTACK_API_SECRET`,
placeholder Postgres passwords (`EVENTS_POSTGRES_PASSWORD`, `EVENTS_POSTGRES_API_PASSWORD`,
`POSTGRES_LEADSMAN_PASSWORD`), loopback-bound event API/DB. Rotate the secrets, add MQTT auth + TLS,
and lock down origins/binds before exposing any of this beyond a trusted private network.

Note that alert bodies contain device names and measured values. If you point a webhook destination
at anything off-device, use `"webhookAuth": "hmac"` and HTTPS — `token` and `bearer` put a
bearer-equivalent secret on the wire with no replay protection. Messaging providers all use HTTPS and
their own credentials.

The `farm` profile adds three more, all off unless you name the profile:

- **The curation API has no authentication and no TLS**, and it writes. It is published on loopback
  only for that reason; move that bind only behind both. It refuses any request carrying an `Origin`
  header, which is what keeps a browser page from reaching it, not a substitute for auth.
- **`farmdata` ships placeholder passwords** for the owner and for both minted login users. The two
  services connect as least-privilege logins rather than the owner — the GraphQL layer holds
  `SELECT` and nothing else, which is what makes it read-only by role rather than by convention —
  but the passwords are still `changeme-*` until you rotate them.
- **`farmdata-api` is read-only but not unauthenticated-safe**: it exposes every reading and every
  device to anyone who can reach it, with GraphiQL on by default. Loopback-bound for that reason —
  and note that a loopback bind is a guard against the LAN, not against the operator's own browser,
  which sits on the near side of it. So, like the curation API, it refuses cross-origin browser
  requests: a page you happen to visit cannot read your farm's telemetry off `127.0.0.1`, and cannot
  make this run queries blind either. GraphiQL still works, because the refusal compares `Origin`
  against `Host` rather than refusing every `Origin` outright. What it does **not** stop is DNS
  rebinding — a page whose name resolves to this address looks same-origin to the browser, and
  nothing here pins `Host` to an allowlist; browsers' own local-network restrictions are the
  mitigation. Before this goes anywhere but loopback it needs all three: TLS in front, real
  authentication in front, and `FARM_API_GRAPHIQL=false`.
