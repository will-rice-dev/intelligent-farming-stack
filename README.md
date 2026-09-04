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
                                     |                                        |
                        events-api (PostGraphile, GraphQL :5050)     (Leftenant join monitor, ws :9001)

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
available on every column. At bench volumes the unindexed scans are fine; add indexes on
`event_up (time)` / `event_up (dev_eui)` (etc.) before relying on those filters at scale.

> First boot ordering is handled for you: a one-shot `events-schema-wait` blocks `events-api` until
> ChirpStack has created `event_up`, so the GraphQL schema is populated on the first `up` (no manual
> restart). Send one device uplink (or trigger a join) to see rows.

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

### Proving it end to end

`scripts/farm-e2e.sh` boots the farm profile with the mock fleet and walks the whole path: uplinks
land as normalized, property-stamped readings, every metric resolves in the dictionary, the store
answers GraphQL, a device is curated through the curation API, and the curation-lag alarm is
asserted by its exit code. Two properties are seeded rather than one, so **property stamping across
a placement change** is provable at all: a device is moved onto the second through the curation API
and its readings split at the move instant — everything measured before it keeps the property it was
measured under, everything after takes the new one. A synthetic message carries the sharp edge, since
the mock fleet has no datalogger to emit one: a single uplink whose `history[]` entry is timestamped
inside the closed window and whose own reading is measured now lands **two readings on two
properties from one batch**, which is the whole of what "as of measurement time" means. It also
publishes a `join` and a `status` event so `telemetry.device_event` is exercised, and redelivers
both to prove the lifecycle key dedupes — those are fixtures because they have to be: the mock fleet
is ABP-activated and requests no device status, so ChirpStack publishes neither event for it. It then
puts the path under the nine failures it has to survive — the
database stopped underneath it, the bridge stopped while the broker keeps receiving, the bridge
killed outright, then the broker itself restarted under a live bridge, restarted with a backlog
queued, and killed outright, then the whole box power-cycled at once, and finally the database and
the broker each *frozen* rather than stopped — and checks that
ingestion resumes each time with nothing left behind. Each
recovery is asserted per message rather than by count: the uplink ids
ChirpStack's archive held at the moment the failure ended all have to reach `farmdata`, and since
the mock fleet publishes throughout, only a set can carry that — a count bar taken at the same
moment is met by the next few uplink rounds with the whole backlog discarded. A red step names the
uplinks that went missing.

**The broker steps are the load-bearing half**, because the bridge holds nothing in its own process:
it acknowledges a message only after committing the reading, and leans on the broker's
persistent-session queue as the buffer. So mosquitto's durability *is* the "an outage costs latency,
not data" guarantee rather than a detail of it — and that guarantee has a scope worth stating.
`persistence true` is a periodic **checkpoint**, not a journal: mosquitto writes its session database
on a clean exit, on `SIGUSR1`, and every `autosave_interval` seconds, and nowhere else. A broker that
shuts down cleanly hands the queue back intact. A broker killed outright hands back only what its
last checkpoint caught, and mosquitto's default interval is 1800 seconds — so `mosquitto.conf` sets
**30s**, and the killed-broker step stops the mock fleet and then waits one interval, read from that
file, before pulling the plug — so the whole archive has been checkpointed when the kill lands and
every uplink in it is asserted to survive.

Stopping the fleet is what makes that sound rather than lucky. The step's own assertion covers only
the set it froze, but the end-of-run check covers the **whole** archive, and an uplink archived after
the last checkpoint tick dies unsaved in the SIGKILL. Left publishing, the step would be staking the
run's strongest assertion on where the autosave clock happened to be — and a bench that genuinely
loses an uplink stays red on every later run until its volumes are destroyed. So the residual window
is real and is stated rather than tested: an unclean death costs up to `autosave_interval` seconds of
queue. That is the guarantee's scope, and the bench stays outside it by construction.

What an unclean death costs is the whole session, not just its queue: the reconnect comes back with
session-present clear, meaning the broker has forgotten the *subscription* as well. A subscriber that
subscribed once at startup would then sit connected to a broker that never speaks to it again — a
farm going quiet rather than a farm losing a few readings, and silent on both sides. The bridge
re-subscribes on every connect, and the first broker step asserts that end to end by bouncing the
broker under a live bridge and watching ingestion continue.

The last broker step also asserts that the **publish** path recovered, not just the consumer. Every
other comparison is against uplinks the archive held *before* the broker died, so a ChirpStack or
gateway bridge that never reconnected would leave both stores frozen at identical contents and pass
every check — including the settled one at the end, which compares the two stores to each other. So
it waits for the archive to grow again: a fresh uplink getting all the way from a mock sensor through
the gateway bridge, the restarted broker, and ChirpStack into `event_up`.

Nothing published *through* a stopped broker reaches either store — the gateway bridges reach
ChirpStack over mosquitto too — so both stores go quiet together while it is down, which is what
keeps the per-message comparison honest across a broker outage.

**The seventh failure is the one an operator actually asks about.** The other six each break one
component, and six recoveries composing is a different claim from one whole-box recovery. So the last
step power-cycles everything in a single `docker compose restart` — which is not the same as a
`down`/`up`, and the difference is the point: `depends_on` conditions gate `up`, not `restart`, so
the bridge loses its `mosquitto: service_healthy` gate and `farmdata-api` loses both of its. That is
exactly what a Docker daemon coming back after a power cut does to them, and nothing else here
reaches it. Nor is it theoretical: on a verified run compose brought `mock-sensors` up *first* —
before the ChirpStack and gateway bridge it publishes through existed — started `telemetry-bridge`
and `farmdata-api` *before* `farm-postgres`, and left `farm-postgres` and `redis` for last. Every
one of those orderings is forbidden on `up`. Four things only this step exercises: the bridge starting cold against a half-up broker
and database; `farmdata-api` racing `farm-postgres`; the three one-shots (`provisioner`,
`events-schema-wait`, `farmdata-migrate`) re-running, whose idempotency was asserted in prose and
nowhere else; and redis, `chirpstack-postgres`, ChirpStack and the gateway bridge all re-forming the
publish chain in no particular order.

It carries three assertions no other step can make. Each one-shot re-ran **and** exited 0 — checked
by `StartedAt`, because a container that was skipped has the same status and exit code as one that
succeeded, so the exit code alone would pass over a compose version that quietly left them alone.
The provisioner **reused** the tenant API key rather than minting a new one: the token is only
returned at creation, so a re-mint would leave the running bridge holding the old one and every
reconcile sweep 401ing while ingest carried on looking healthy. And the operator's curated placement
survived, which is the only thing checking that `farmdata-migrate` re-applying over a warm database
leaves a person's decision alone.

**This step quiesces the fleet first, and that is a scope limit rather than caution.** ChirpStack
dispatches its integrations concurrently — `futures::future::join_all`, not the order
`enabled=["mqtt","postgresql"]` is written in — so for any uplink it is handling, the MQTT publish
and the `event_up` write race each other, and a publish refused by a broker going down in the same
window is logged rather than retried. An uplink can therefore land in the archive with its publish
never having happened: an id `farmdata` will never receive, which reddens the end-of-run comparison
on this run and every later one against a kept bench. Nothing downstream can fix it, because the two
integrations are not transactional with each other. **So the ingest guarantee begins at the broker,
not at ChirpStack** — the same shape of scoping as the checkpoint window above, and the reason the
fleet is stopped and allowed to settle before the plug is pulled. What makes the frozen set mean
anything with the fleet quiet is the backlog: the bridge is stopped for a few uplink rounds first, so
the ids being waited for are genuinely still in the broker rather than already in `farmdata`.

**The eighth and ninth failures are a different shape from the seven before them, and that is the
point of adding them.** A stop, a kill and a restart are all _polite_: the socket closes, so the
peer's departure arrives as an error and every waiter is woken by something the kernel said out
loud. `docker compose pause` sends SIGSTOP, which closes nothing — established connections stay
established, the kernel keeps completing handshakes on the stopped process's behalf, and nothing
ever answers. Every wait on such a peer is unbounded unless the waiter brought its own bound, and a
bridge sitting inside one looks exactly like a bridge with nothing to do.

So those two steps assert that the wedge is **visible** — a bounded-deadline line in the log, a
rising `writeRetries` in the bridge's own counter report — rather than that nothing was lost, which
while a peer is frozen is not a claim anyone can make: nothing is acknowledged, so nothing can be.
The counter matters more than it looks, because the expectation _inverts_ between the two database
failures. Across the clean stop/start of failure 1, `writeRetries` is legitimately 0: the socket
error reaches the writer session's reconnect loop first, and the consumer only ever sees one slow
write. Under a freeze it cannot be 0, because there is no socket error for that loop to absorb.

**The `farmdata-api` check after failure 8 asserts less than it looks like it does**, which is worth
stating rather than letting a green step imply the stronger thing. The read API is *idle* for the
whole freeze — nothing in the step queries it — so its pool has no statement in flight, and an idle
pooled connection going quiet costs nothing: the first query after the thaw answered in 29 ms with
`RestartCount` still 0, so it never died and `restart: unless-stopped` never fired. That a freeze
the read API slept through leaves it working is worth knowing, and it is not the same as recovering
from a wedge. Testing the wedge means holding a query open across the freeze; PostGraphile's pool
has no Node-side statement bound, so the honest expectation is that it hangs, and the fix would be a
`query_timeout` in `farm-api/server.js` rather than another assertion. Unlike the bridge, nothing is
lost either way — a stateless reader that restarts is a liveness question, not an ingest one.

Failure 9 quiesces the fleet first for exactly the `join_all` reason failure 7 does. What ends the
silence there is MQTT keepalive and nothing else, so the step reads the interval out of the bridge
image rather than carrying a copy and scales its own patience to it — and it has to prove the bridge
is _connected and subscribed_ before freezing the broker, because a bridge caught mid-reconnect
would be bounded by mqtt.js's `connectTimeout` instead, which is a different mechanism and a weaker
claim. `wait_for_broker` does not show that; it says the broker answers a probe of the script's own.

**Failure 9 deliberately makes no backlog claim, and the first draft did.** The bridge drains a few
hundred messages a second, so a backlog queued before the freeze is already in `farmdata` by the
time the pause lands — and with the fleet quiesced, a set frozen from the archive is satisfied
before the freeze even begins. It would have passed without the broker being touched. The "session
survived" claim needs the CONNACK's session-present flag, which is invisible from out here; the
bridge repo's own proof owns it. What this step asserts instead is ingest resuming end to end: the
fleet restarts, a _new_ uplink has to reach the archive, and only then does every id the archive
holds have to reach `farmdata` — a set that now contains uplinks which did not exist before the
freeze.

One practical note if you write another of these: nothing can read `farmdata` while `farm-postgres`
is paused. `farm_psql` and `wait_for_broker` are `docker compose exec`, and the daemon refuses that
against a paused container outright — immediately, not by hanging. The bridge's experience of the
same container is the opposite, and the asymmetry is the whole subject: it holds a TCP connection
SIGSTOP never closed, so its statement goes quiet with no error at all.

The database-outage step re-asserts `farmdata-api` itself as well, not only the store behind it.
Every other check after a failure reads `farmdata` through `psql`, so a read API left dead by a
database blip would pass the rest of the run — and unlike the bridge, it has no retry loop of its
own: it takes the connection error, exits, and comes back only because it carries
`restart: unless-stopped`. That policy is load-bearing, so something has to prove it. The check
looks at the response body rather than the port, because PostGraphile stays up and listening while
it retries introspection, answering nothing but errors.

**Then it sends the path bad data**, which is the other half of what a farm produces and the half
this bench never saw. Four steps, and the first is why the section exists: the bridge is serial and
acknowledges a message only after committing it, so a message it fails to ack stays at the head of
the broker's queue and is redelivered forever with everything behind it waiting. A poison message
that is not acked therefore does not lose one reading — it stops the farm, silently, until somebody
notices. So garbage is published into the middle of an offline backlog, real uplinks on both sides
of it, and the whole backlog has to drain past it. Then timestamps a decoder should never emit: a
message ten minutes in the future, which is dropped **whole** because `occurred_at` is the raw
table's partition key and a row in the kept default partition blocks that month's partition from
ever being created; and an ancient reading inside a `history[]` entry, where the blast radius is
deliberately different — that reading is dropped and the raw capture is kept. Then a redelivery,
published twice on purpose. And last, a device whose ChirpStack codec throws on every uplink, whose
raw capture has to land with **no decoded readings**, because ingestion is never gated on decode.
Not *zero* readings: the adapter mints `gatewayRssi`/`gatewaySnr` from the uplink's `rxInfo`
whenever `FARM_BRIDGE_SIGNAL_HEALTH` is on, which is radio metadata rather than anything the codec
produced — so a device with no working decoder still reports how well it was heard, and the step
asserts that too, since a device with no uplinks at all would satisfy the zero on its own.

**Two of those are only assertable because the daemon now reports its counters.** A message the
bridge drops deliberately leaves no row to find, and a redelivery that was correctly deduped leaves
exactly the rows a redelivery that never happened would — every trace of a successful replay is
collapsed by a primary key. So the bridge logs `getReport()` on an interval
(`FARM_BRIDGE_REPORT_INTERVAL_SECONDS`, default 300), once more on shutdown, and immediately on
`SIGUSR2`, which is what the script uses: `docker compose kill -s USR2 telemetry-bridge` and read
the `ingest report:` line. The one trap is worth knowing before writing another step on it — **a
bridge restart is a new process and every counter starts at zero**, so a mark taken before a step
that stops or kills the bridge is not a baseline for anything after it.

The broken-codec device is a real one, provisioned by `mock-sensors` like the other 23, sending real
decode-verified bytes behind a profile carrying a codec that raises. That is the only way to learn
what ChirpStack itself does with a failing decoder — it publishes and archives the uplink anyway,
with no `object` — which is the fact everything downstream rests on.

```sh
bash scripts/farm-e2e.sh              # tears the stack down afterwards
FARM_E2E_KEEP=1 bash scripts/farm-e2e.sh   # leave it running (fast iteration)
```

It takes around twenty-five minutes, most of it waiting on uplink rounds, on containers
stopping and starting, on the one checkpoint interval the killed-broker step sits through, on the
bridge's own 30s write deadline expiring under the frozen database, and on
the offline backlogs the poison and broker-freeze steps have to build before they have anything to
drain. Counts are asserted
as floors, never as exact fleet totals: `mock-sensors` sends one unacknowledged UDP datagram per
uplink with no retransmit, so an occasional frame never reaches ChirpStack at all, and that is a
transport flake rather than a bridge regression. What proves nothing was lost is the comparison
against ChirpStack's own archive, which is flake-immune for the same reason — a datagram that never
arrived is in neither store, so it is on neither side of it.

The deterministic versions of those failures — including a daemon killed in the exact window between
its commit and the message's acknowledgment, and a broker whose persisted session is deleted
outright — live in the telemetry-bridge repo's own `npm run db:exercise:resilience`, which can drive
the consumer in-process and read the CONNACK's session-present flag directly. This script proves the
same recoveries for the packaged daemon on the real ChirpStack path. The power cycle has a
counterpart there too, and the split is the same: that exercise restarts the broker and the database
in one call under a live consumer, so it can assert on the consumer's own counters that both
reconnect loops recovered and neither wedged the other, while what only this script can show is the
other ten services coming back with it.

The deliberate total loss stays over there for a reason: an uplink destroyed on this bench is missing
from `farmdata` for good, so it would fail the end-of-run "nothing was lost" comparison on this run
and every later run against a kept bench. The bridge's fixtures are reserved device EUIs it deletes
at the start of each run, so it can afford to destroy a session and assert what that costs.

That in-process form is also the only place a redelivery can be **observed**. Every trace of one is
collapsed by a primary key — `reading`, `reading_latest`, `ingest_event` and `device_event` all
dedupe on conflict — and the daemon logs connection lifecycle, faults and shutdown but never its
counters, so from out here a replay that was deduped and a redelivery that never happened are
indistinguishable. Successful idempotence is silent by construction. What this script can prove
after the kill is that ingestion resumed and nothing was lost; that the replay wrote nothing twice
is asserted in the bridge repo, against counters.

The same split applies to the placement steps. What the bench proves is the claim through the real
pipe: a real fleet device moved through the real curation API, whose readings then accumulate either
side of the move for the rest of the run and are split at the end. What the bridge repo's
`npm run db:exercise:placement` adds is the case this script deliberately leaves out — a *backdated*
correction, which does **not** re-stamp readings already stored. That has to live over there: a
device whose history was corrected retroactively is exactly a device whose stored stamps no longer
agree with its current windows, and this run ends by asserting that agreement over every reading in
the database. Deterministic proof there, exact invariant here.

**The run ends with four cross-table sweeps**, and they are last because that is the only moment
nothing is racing and there is a full run's worth of rows to be wrong about. `reading_latest` must
equal the true newest reading for every `(device, metric, channel)` — timestamp *and* value, since an
intra-batch collision resolved one way in the fact table and the other in the mirror would publish a
value no reading row holds. Every reading a placement window covers must carry that window's
property; the readings no window covers are counted and explained rather than ignored, and there are
two honest reasons for one — a device's first uplink is measured a moment *before* the window
auto-registration opens for it, and a codec may supply its own measurement `time`, so a datalogger
reading can legitimately predate the device's registration by months (this bench's GPS tracker emits
one about seventy days back). Both take the writer's documented fallback. What is *not* honest is an
uncovered reading measured **after** its device's history began: that means the history has a gap and
the fallback answered for a measurement some window should have owned, and it is asserted to be zero.
The moved device's split is asserted per row against the move instant the API wrote. And the
lifecycle fixtures are still exactly the rows they wrote.

Then the posture the rest of it rests on: **every published `farm` port is asserted to be bound to
`127.0.0.1`**, read out of the running containers rather than out of `docker-compose.yml` so an
`.env` override is caught too. The curation API writes and has no authentication and no TLS; the
GraphQL layer exposes every reading with GraphiQL on. Both are safe on this bench only because of
that bind, so a compose edit dropping the prefix would publish an unauthenticated write API to the
network — and until this step, nothing in the run would have noticed. Scoped to the farm profile
deliberately: mosquitto, ChirpStack, its REST gateway, both gateway bridges and Leftenant are
published unbound on purpose, being the LAN-facing half of the bench.

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

Confirming a device is on the property it already defaulted to **is** a curation, not a no-op: until
a person says so the placement was written by a machine, and the response says `confirmed_placement`
precisely because the property did not change. That is the commonest thing an operator does here.

### The curation-lag alarm

The guard against readings being quietly attributed to the property a device defaulted to rather
than the one it is really on. It reports auto-created devices that have gone more than
`FARM_BRIDGE_CURATION_LAG_DAYS` (default 7) without anyone placing them, and it is a subcommand of
the bridge rather than an endpoint, so a cron job or a monitor can read its exit code:

```sh
docker compose run --rm --no-deps telemetry-bridge curation-lag
# 0 = nothing lagging · 2 = devices are lagging · 1 = the check itself failed
```

The same check also runs on a timer inside the daemon (`FARM_BRIDGE_CURATION_CHECK_INTERVAL_SECONDS`),
where it writes the same report to the log.

**Two things to know before pointing anything at it.** It serves no authentication and no TLS in
this release, which is why it is published on loopback only. And any request carrying an `Origin`
header is refused with 403 — deliberately, since there is no auth to protect a browser caller with
— so this is a `curl`/CLI surface, not one to call from a web page.

### Where the values come from

`farm/projection.json` is the bench's organization and properties, and it has exactly one job beyond
seeding: `FARM_BRIDGE_PROPERTY_ID` is left blank in `.env` and derived from this file's
`default_property_id`, so the property the seeder writes and the property the bridge uses cannot
drift apart. Point at a real property by editing this file, not by pasting a UUID in two places.

It seeds **two** properties — Bench Field, which is the default every uncurated device lands on, and
Bench South Field, which exists so there is somewhere to move a device *to*. That is not decoration:
with one property seeded, "every reading is stamped with the property valid when it was measured" has
only one answer it could possibly give, and the end-to-end script's placement steps would be
asserting nothing. Adding a property is an addition to `properties[]` and nothing else — the seeder
upserts on every `up`, and leaving `default_property_id` alone keeps the bridge's derivation and
every existing assertion unchanged.

The ChirpStack API key the inventory reconciler uses is read from `/shared/config.json` — minted by
the provisioner at run time, so no environment variable can carry it. That is the same file
Leftenant reads.

### Partition maintenance

`reading` and `ingest_event` are partitioned monthly with retention, and **the bridge daemon
maintains them**: one pass before it opens its broker connection, then every
`FARM_BRIDGE_MAINTAIN_INTERVAL_SECONDS` (default a day). The startup pass is the load-bearing half —
premake keeps three months of children ahead, so a box powered off for longer than that would
otherwise write its first uplink into a default partition, and a default partition holding a row for
some month is what makes a partition set permanently unmaintainable. The pg_partman background
worker is still preloaded but stays unpointed, and is not the mechanism here.

On demand, and for a monitor:

```sh
docker compose run --rm --no-deps telemetry-bridge maintain
# 0 = every set healthy · 2 = a set is degraded · 1 = the run could not happen
```

**The exit code is the verdict, and it has to be.** pg_partman answers a partition set it cannot
maintain with `RAISE WARNING`, nulls that set's `maintenance_last_run`, and returns successfully —
so nothing downstream of an exit status can see the one condition worth paging on. The run is
followed by three catalog reads: that maintenance actually moved for every set, that a child already
covers traffic 45 days out (the forward check, which fires with weeks of margin), and that no
default partition holds a row past its newest child. The verdict also rides on the bridge's ingest
report, under `maintenance`.

The headroom check on its own, if you want to ask the database directly:

```sh
docker compose exec farm-postgres psql -U farmdata_owner -d farmdata -c \
  "SELECT pc.parent_table,
          (partman.show_partition_name(pc.parent_table,
             (now() + interval '45 days')::text)).table_exists
     FROM partman.part_config pc"
```

Maintenance connects as `FARM_BRIDGE_MAINT_LOGIN_USER`, a member of `partman_maintainer`, which
**owns** both partition sets — `ATTACH PARTITION` and `DROP PARTITION` require owning the parent and
no `GRANT` confers ownership. Leave that pair blank and the daemon still runs, says maintenance is
unscheduled at startup, and repeats it in every ingest report. The full reasoning, and the runbook
for a `degraded` answer, are in the telemetry-bridge repo's README under "Partitioning and
retention".

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
loopback-bound event API/DB. Rotate the secret, add MQTT auth + TLS, and lock down origins/binds
before exposing any of this beyond a trusted private network.

The `farm` profile adds three more, all off unless you name the profile:

- **The curation API has no authentication and no TLS**, and it writes. It is published on loopback
  only for that reason; move that bind only behind both. It refuses any request carrying an `Origin`
  header, which is what keeps a browser page from reaching it, not a substitute for auth.
- **`farmdata` ships placeholder passwords** for the owner and for all three minted login users. The
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
