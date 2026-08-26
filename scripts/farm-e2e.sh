#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Intelligent Farming Foundation
#
# End-to-end proof of the farm telemetry path: a mock sensor's uplink through
# ChirpStack and mosquitto into the telemetry bridge, landing as normalized,
# property-stamped readings in farmdata, queryable over GraphQL, with a device
# curated through the curation API and the curation-lag alarm asserted by its
# exit code. Then the same path put under three failures it has to survive.
#
# The sibling scripts/e2e.sh proves the *event archive* path (mock-sensors ->
# ChirpStack -> the PostgreSQL integration -> events-api). This one proves the
# farm store beside it, which is a different subscriber on the same broker.
# Neither reads the other's database, and this script asserts that too.
#
# Set FARM_E2E_KEEP=1 to leave the stack running afterwards (fast iteration).
#
# Prerequisite: the farm images are built and tagged locally. They are not
# published anywhere yet, so a checkout of the telemetry-bridge repo has to
# build them first:
#
#   cd ../telemetry-bridge && npm install && npm run images:build
#
# A note on the assertions below. mock-sensors emits one unacknowledged UDP
# datagram per uplink with no retransmit, so an occasional frame never reaches
# ChirpStack at all. Every count here is therefore a floor or a cross-check
# against what ChirpStack actually received, never an exact fleet total: a
# dropped datagram is a transport flake, and asserting 23 devices exactly would
# turn it into a red run that reads like a regression in the bridge.
#
# Which is why every recovery is asserted against the *archive* rather than
# against where the bridge's own count stood before the failure. The mock fleet
# publishes throughout, so "more than before" is met by the next uplink round
# and would pass with everything the outage held silently discarded. Do not
# simplify those back to a `-gt` on a prior count.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# ── resolve configuration (shell env > .env > .env.example > built-in default) ──
# The same precedence, the same files, and the same deliberate not-sourcing as
# scripts/e2e.sh: a .env is data, and sourcing it would execute any $(...) a
# stray line happens to contain.
dotenv_get() {
  local file="$1" key="$2" line value=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    case "$line" in
      "$key="*) value="${line#"$key"=}" ;;
      "export $key="*) value="${line#export "$key"=}" ;;
      *) continue ;;
    esac
  done < "$file"
  case "$value" in
    '"'*'"')
      value="${value#\"}"
      value="${value%\"}"
      ;;
    "'"*"'")
      value="${value#\'}"
      value="${value%\'}"
      ;;
    *)
      value="${value%%[[:space:]]#*}"                  # strip ` # comment`
      value="${value%"${value##*[![:space:]]}"}"       # rtrim
      ;;
  esac
  printf '%s' "$value"
}

# cfg VAR DEFAULT — set VAR unless it already has a value in the environment.
cfg() {
  local var="$1" def="$2"
  # Separate statement on purpose: in bash 3.2 (still the /bin/bash on macOS)
  # the names in a single `local` are all declared before any of its assignments
  # are expanded, so `local var="$1" val="${!var-}"` reads an unset `var`.
  local val="${!var-}"
  [ -z "$val" ] || return 0
  val="$(dotenv_get "$ROOT_DIR/.env" "$var")"
  [ -n "$val" ] || val="$(dotenv_get "$ROOT_DIR/.env.example" "$var")"
  [ -n "$val" ] || val="$def"
  printf -v "$var" '%s' "$val"
}

cfg FARM_POSTGRES_USER farmdata_owner
cfg FARM_POSTGRES_DB farmdata
cfg FARM_API_HOST_PORT 5051
cfg FARM_CURATION_HOST_PORT 8092
cfg FARM_BRIDGE_CURATION_LAG_DAYS 7
cfg EVENTS_POSTGRES_USER events
cfg EVENTS_POSTGRES_DB chirpstack_events
cfg EVENTS_API_HOST_PORT 5050
cfg MOCK_INTERVAL_SECONDS 15
cfg FARM_POSTGRES_IMAGE intelligent-farming/farm-postgres:dev
cfg FARMDATA_MIGRATE_IMAGE intelligent-farming/farmdata-migrate:dev
cfg TELEMETRY_BRIDGE_IMAGE intelligent-farming/telemetry-bridge:dev

FARM_API_URL="http://localhost:${FARM_API_HOST_PORT}/graphql"
EVENTS_API_URL="http://localhost:${EVENTS_API_HOST_PORT}/graphql"
CURATION_URL="http://localhost:${FARM_CURATION_HOST_PORT}"

echo "[farm-e2e] graphql ${FARM_API_URL} · curation ${CURATION_URL}"
echo "[farm-e2e] mock uplink interval ${MOCK_INTERVAL_SECONDS}s · curation-lag threshold ${FARM_BRIDGE_CURATION_LAG_DAYS}d"

# ── helpers ───────────────────────────────────────────────────────────────────

fail() {
  echo "[farm-e2e] FAIL: $*" >&2
  exit 1
}

step() {
  echo ""
  echo "[farm-e2e] == $* =="
}

# One scalar out of farmdata, as the owning role. Deliberately expands inside
# the container (the healthcheck's trick): compose resolves FARM_POSTGRES_* from
# .env, and a host-side expansion of an overridden user or database name would
# address a different database than the one running.
farm_psql() {
  docker compose exec -T farm-postgres \
    sh -c 'psql -v ON_ERROR_STOP=1 -qtAX -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"
}

events_psql() {
  docker compose exec -T events-postgres \
    sh -c 'psql -v ON_ERROR_STOP=1 -qtAX -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' _ "$1"
}

# The curation API refuses any request carrying an Origin header, so this is
# curl rather than anything browser-shaped, and it stays that way.
curation_get() {
  curl -fsS "${CURATION_URL}$1"
}

curation_post() {
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$2" "${CURATION_URL}$1"
}

graphql() {
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$(node -e 'process.stdout.write(JSON.stringify({query: process.argv[1]}))' "$1")" \
    "$FARM_API_URL"
}

# Read one value out of a JSON response by accessor path (".devices[0].name").
# The body is JSON.parsed rather than evaluated -- only the accessor, which is
# this script's own string, is ever executed.
json_field() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const o=JSON.parse(s);
    const v=new Function("o","return o"+process.argv[1])(o);
    process.stdout.write(v===undefined||v===null?"":String(v));
  })' "$1"
}

# Fails unless the GraphQL response is error-free. Written as an `if` rather
# than `grep -q ... && fail`, because under `set -e` a grep that finds nothing
# makes the whole `&&` list return non-zero and kills the script -- so the
# no-errors case, which is the passing one, would be the one that aborts.
assert_graphql_ok() {
  local label="$1" response="$2"
  if printf '%s' "$response" | grep -q '"errors"'; then
    fail "GraphQL returned errors for ${label}: $response"
  fi
  echo "[farm-e2e] ok: ${label}"
}

# Wait until a farmdata scalar query satisfies a predicate, or give up. Every
# wait in this script goes through here so a hang is always a named failure
# with the last value it saw, rather than a script that stopped.
wait_for() {
  local what="$1" query="$2" predicate="$3" timeout="${4:-120}"
  local deadline=$(( $(date +%s) + timeout )) value=""
  while :; do
    value="$(farm_psql "$query" 2>/dev/null || true)"
    if [ -n "$value" ] && [ "$value" -ge 0 ] 2>/dev/null && eval "[ $value $predicate ]"; then
      echo "[farm-e2e] $what: $value"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "$what: waited ${timeout}s, last value \"$value\" (wanted $predicate)"
    sleep 2
  done
}

# ── teardown ──────────────────────────────────────────────────────────────────

started=0
cleanup() {
  local code=$?
  if [ "$started" = "1" ] && [ "${FARM_E2E_KEEP:-0}" != "1" ]; then
    echo ""
    echo "[farm-e2e] tearing down (set FARM_E2E_KEEP=1 to keep the stack running)"
    docker compose --profile farm --profile mock down
  fi
  exit "$code"
}
trap cleanup EXIT

# ── boot ──────────────────────────────────────────────────────────────────────

step "booting the farm profile"

for image in "$FARM_POSTGRES_IMAGE" "$FARMDATA_MIGRATE_IMAGE" "$TELEMETRY_BRIDGE_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 \
    || fail "image $image is not in this host's image store -- build it first: (cd ../telemetry-bridge && npm run images:build)"
done

# The one-shots (provisioner, farmdata-migrate, events-schema-wait) are
# deliberately absent from this list: `--wait` aborts if a service it was told
# to wait for exits, and all three are supposed to exit. They are pulled in as
# dependencies of the services below.
SERVICES="chirpstack-postgres redis mosquitto events-postgres chirpstack chirpstack-rest-api chirpstack-gateway-bridge events-api farm-postgres telemetry-bridge farmdata-api"

if [ -z "$(docker compose --profile farm ps -q telemetry-bridge 2>/dev/null)" ]; then
  # shellcheck disable=SC2086
  docker compose --profile farm up -d --wait --wait-timeout 300 $SERVICES
  started=1
else
  echo "[farm-e2e] farm profile already running — reusing it"
fi

step "starting the mock sensor fleet"
docker compose --profile mock up -d mock-sensors

# ── the pipeline ──────────────────────────────────────────────────────────────

step "waiting for readings to land"

# A floor rather than the fleet's 23: one lost datagram is a transport flake,
# not a regression. What makes this a real assertion is the cross-check below
# against what ChirpStack itself received.
wait_for "devices auto-created" \
  "SELECT count(*) FROM registry.device WHERE auto_created = true" "-ge 15" 180
wait_for "readings written" \
  "SELECT count(*) FROM telemetry.reading" "-ge 100" 180

step "stopping the mock fleet so its loop cannot race the assertions"
docker compose --profile mock stop mock-sensors
# The bridge is serial and acks after commit, so anything already published is
# still draining for a moment after the publisher stops.
sleep 5

step "asserting what landed"

unstamped="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE property_id IS NULL")"
[ "$unstamped" = "0" ] || fail "$unstamped reading(s) landed with no property_id -- every reading is stamped as of its measurement time"
echo "[farm-e2e] every reading is property-stamped"

default_property="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("farm/projection.json","utf8")).default_property_id)')"
off_property="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE property_id <> '${default_property}'")"
[ "$off_property" = "0" ] || fail "$off_property reading(s) are stamped with a property that is not the seeded default"
echo "[farm-e2e] all readings are stamped with the seeded property ${default_property}"

unknown_metrics="$(farm_psql "SELECT count(*) FROM telemetry.reading r WHERE NOT EXISTS (SELECT 1 FROM registry.metric m WHERE m.metric = r.metric)")"
[ "$unknown_metrics" = "0" ] || fail "$unknown_metrics reading(s) carry a metric that is not in the dictionary"
echo "[farm-e2e] every metric resolves in the dictionary — the vocabulary is the taxonomy"

# The flake-immune cross-check, and the assertion that actually proves nothing
# was lost between ChirpStack and farmdata. Both stores sit downstream of the
# same ChirpStack, so a datagram that never arrived is missing from both and
# the comparison still holds; a message the bridge dropped is missing from only
# one, which is what this catches. The archive counts uplinks; the bridge
# captures one ingest_event per uplink it consumed.
archived="$(events_psql "SELECT count(*) FROM event_up")"
captured="$(farm_psql "SELECT count(*) FROM telemetry.ingest_event WHERE event_type = 'up'")"
echo "[farm-e2e] ChirpStack archived ${archived} uplink(s); the bridge captured ${captured}"
[ "$captured" -ge "$archived" ] \
  || fail "the bridge captured fewer uplinks ($captured) than ChirpStack archived ($archived) -- messages were lost between the broker and farmdata"

# ── GraphQL ───────────────────────────────────────────────────────────────────

step "querying farmdata over GraphQL"

assert_graphql_ok "allReadings" \
  "$(graphql 'query { allReadings(first: 5) { nodes { deviceId metric valueNum measuredAt } } }')"
assert_graphql_ok "allReadingLatests" \
  "$(graphql 'query { allReadingLatests(first: 5) { nodes { deviceId metric valueNum } } }')"
assert_graphql_ok "allDevices" \
  "$(graphql 'query { allDevices(first: 5) { nodes { deviceId name autoCreated } } }')"
assert_graphql_ok "allProperties" \
  "$(graphql 'query { allProperties { nodes { propertyId name } } }')"

# The category pivot views are the reason the codec vocabulary is worth having:
# one view per device category, columns rather than rows. Whichever category
# this fleet actually produced is the one worth querying.
category="$(farm_psql "SELECT category FROM registry.device WHERE category IS NOT NULL GROUP BY category ORDER BY count(*) DESC LIMIT 1")"
if [ -n "$category" ]; then
  # soil-monitor -> allSoilMonitorVs
  field="all$(printf '%s' "$category" | awk -F- '{for(i=1;i<=NF;i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2)}')Vs"
  assert_graphql_ok "the ${category} pivot view (${field})" \
    "$(graphql "query { ${field}(first: 3) { nodes { deviceId measuredAt } } }")"
else
  fail "no device was categorized, so no pivot view could be exercised"
fi

# ── curation ──────────────────────────────────────────────────────────────────

step "curating a device"

worklist="$(curation_get '/v1/devices?needsCuration=true')"
device_id="$(printf '%s' "$worklist" | json_field '.devices[0].deviceId')"
[ -n "$device_id" ] || fail "the worklist is empty, but every device here was auto-created and none has been placed: $worklist"
echo "[farm-e2e] worklist offers ${device_id}"

# The alarm reports auto-created devices older than N days that nobody has
# placed. Nothing on a fresh bench is old enough, so one device is aged past
# the threshold directly -- bench scaffolding, and the only write in this
# script that does not go through an API.
farm_psql "UPDATE registry.device SET created_at = now() - interval '$((FARM_BRIDGE_CURATION_LAG_DAYS + 1)) days' WHERE device_id = '${device_id}'" >/dev/null
echo "[farm-e2e] aged ${device_id} past the ${FARM_BRIDGE_CURATION_LAG_DAYS}-day curation-lag threshold"

set +e
docker compose run --rm --no-deps -T telemetry-bridge curation-lag >/dev/null 2>&1
lag_code=$?
set -e
[ "$lag_code" = "2" ] || fail "curation-lag should exit 2 while a device is lagging, got $lag_code"
echo "[farm-e2e] curation-lag exits 2 — the alarm sees the unplaced device"

# Confirming a device is where it already defaulted to is a real curation act,
# not a no-op: the open window is machine-written until a person says so, and
# this is the commonest thing an operator does on a small farm. The response
# says confirmed_placement precisely because the property did not change.
assign="$(curation_post "/v1/devices/${device_id}/assignment" \
  "{\"propertyId\":\"${default_property}\",\"actor\":\"farm-e2e-operator\"}")"
changed="$(printf '%s' "$assign" | json_field '.changed')"
reason="$(printf '%s' "$assign" | json_field '.reason')"
# `curated` hangs off the open assignment rather than the device, because that
# is literally what it means here: the window is curated when the actor that
# opened it is not one of the machine writers. There is no column for it.
curated="$(printf '%s' "$assign" | json_field '.device.assignment.curated')"
assigned_by="$(printf '%s' "$assign" | json_field '.device.assignment.assignedBy')"
[ "$changed" = "true" ] || fail "confirming a default placement must write: $assign"
[ "$reason" = "confirmed_placement" ] || fail "expected reason confirmed_placement, got \"$reason\": $assign"
[ "$curated" = "true" ] || fail "the open window should read as curated after a person placed it: $assign"
[ "$assigned_by" = "farm-e2e-operator" ] || fail "the open window should name the operator, got \"$assigned_by\""
echo "[farm-e2e] assigned: changed=${changed} reason=${reason} curated=${curated} by=${assigned_by}"

replay="$(curation_post "/v1/devices/${device_id}/assignment" \
  "{\"propertyId\":\"${default_property}\",\"actor\":\"farm-e2e-operator\"}")"
replay_changed="$(printf '%s' "$replay" | json_field '.changed')"
[ "$replay_changed" = "false" ] || fail "the same assignment sent twice must be recognized as a replay: $replay"
echo "[farm-e2e] replayed: changed=${replay_changed} reason=$(printf '%s' "$replay" | json_field '.reason')"

still_listed="$(curation_get '/v1/devices?needsCuration=true' | json_field ".devices.filter(d=>d.deviceId==='${device_id}').length")"
[ "$still_listed" = "0" ] || fail "a curated device must leave the worklist"
echo "[farm-e2e] the curated device left the worklist"

set +e
docker compose run --rm --no-deps -T telemetry-bridge curation-lag >/dev/null 2>&1
lag_code=$?
set -e
[ "$lag_code" = "0" ] || fail "curation-lag should exit 0 once nothing is lagging, got $lag_code"
echo "[farm-e2e] curation-lag exits 0 — the alarm is quiet again"

# ── resilience, against the real containerized daemon ─────────────────────────
#
# The deterministic versions of these live in the telemetry-bridge repo's own
# npm run db:exercise:resilience, which drives the consumer in-process and can
# stand in the exact window between a commit and its PUBACK. What this adds is
# the same failures met by the *packaged daemon*, on the real ChirpStack path,
# with a live publisher upstream that does not stop when the bridge does.

step "resilience: the database goes away under a live bridge"

docker compose --profile mock up -d mock-sensors
sleep "$MOCK_INTERVAL_SECONDS"

# Where the bridge's log stood before the outage. `--tail 200` cannot stand in
# for this: this script reuses an already-running profile, and on a reused bench
# that window still holds the previous run's retry lines -- so the assertion
# would pass on evidence from an outage that ended before this run started.
log_mark="$(docker compose logs --no-color telemetry-bridge | wc -l | tr -d ' ')"

docker compose stop farm-postgres
sleep "$MOCK_INTERVAL_SECONDS"

# Read into a variable rather than piped into `grep -q`. `grep -q` exits at its
# first match; with that match early in the stream `docker compose logs` is
# still writing, takes EPIPE and exits 255, and `pipefail` returns *that* --
# failing the step even though the pattern was found. Command substitution
# reads to the end, so the status reaching `||` is the one that means something.
outage_log="$(docker compose logs --no-color telemetry-bridge | tail -n "+$((log_mark + 1))")"

# Three lines, in the order the bridge can emit them. `connection error` comes
# off the writer session's own socket the moment Postgres goes down; the other
# two only appear once the next uplink is written, so matching on those alone
# makes this depend on the mock fleet's cadence beating the sleep above.
grep -qE 'writer session: connection error|writer session: connect attempt|write failed .*retrying' <<<"$outage_log" \
  || fail "the bridge logged no retry while the database was down -- it did not notice"
echo "[farm-e2e] the bridge is retrying with the database stopped"

# What ChirpStack had archived by the time the database came back, everything
# the outage queued up included. Requiring the bridge to *reach* that, rather
# than merely to pass where it stood, is what makes this a loss check instead of
# a liveness one: the mock fleet never stopped publishing, so "more than before"
# is satisfied by a single fresh uplink and would pass with the whole outage
# dropped. Flake-immune for the same reason the cross-check above is -- a
# datagram that never reached ChirpStack is missing from both stores.
archived_at_recovery="$(events_psql "SELECT count(*) FROM event_up")"
docker compose start farm-postgres
wait_for "uplinks captured after the database came back (archive held ${archived_at_recovery})" \
  "SELECT count(*) FROM telemetry.ingest_event WHERE event_type = 'up'" "-ge $archived_at_recovery" 180
echo "[farm-e2e] the bridge resumed writing on its own — no restart needed"

step "resilience: the bridge goes away while the broker keeps receiving"

docker compose stop telemetry-bridge
# Long enough that several uplink rounds are published with nothing consuming
# them. They are held by mosquitto for the bridge's persistent session; that
# session is why the broker keeps them instead of discarding them.
sleep $(( MOCK_INTERVAL_SECONDS * 3 ))
# The whole backlog, as the archive counts it. This is where a floor was weakest:
# a broker that had silently discarded the queue -- persistence off, the session
# gone clean, max_queued_messages exhausted -- still passes "more than before" on
# the next uplink round, having lost every message it was holding.
archived_at_recovery="$(events_psql "SELECT count(*) FROM event_up")"
docker compose start telemetry-bridge
wait_for "backlog drained after the bridge came back (archive held ${archived_at_recovery})" \
  "SELECT count(*) FROM telemetry.ingest_event WHERE event_type = 'up'" "-ge $archived_at_recovery" 180
echo "[farm-e2e] the broker held the backlog and the bridge drained it"

step "resilience: the bridge is killed outright"

# SIGKILL, so no shutdown path runs at all: whatever was mid-write is
# abandoned without acknowledgment and the broker still holds it. The service
# carries `restart: unless-stopped`, so Docker may well bring it back on its
# own before the `start` below -- which is the point rather than a problem, and
# `start` on an already-running container is a no-op either way.
docker compose kill -s KILL telemetry-bridge
sleep "$MOCK_INTERVAL_SECONDS"
# Taken after the sleep but before the `start`, so it covers what was abandoned
# mid-write as well as what was published while nothing was consuming. If
# Docker's restart policy already brought the bridge back and it is draining by
# now, this is simply a number it has partly reached -- still the one it has to
# arrive at.
archived_at_recovery="$(events_psql "SELECT count(*) FROM event_up")"
docker compose start telemetry-bridge
wait_for "uplinks captured after a SIGKILL (archive held ${archived_at_recovery})" \
  "SELECT count(*) FROM telemetry.ingest_event WHERE event_type = 'up'" "-ge $archived_at_recovery" 180

# Duplicates are structurally impossible -- the reading primary key is the
# idempotency key -- so this is really a check that the constraint is doing
# what the design says it does, on rows a redelivery may well have replayed.
dupes="$(farm_psql "SELECT count(*) FROM (SELECT device_id, metric, channel, measured_at FROM telemetry.reading GROUP BY 1,2,3,4 HAVING count(*) > 1) d")"
[ "$dupes" = "0" ] || fail "$dupes reading key(s) appear more than once"
echo "[farm-e2e] no duplicate readings after a kill and a redelivery"

step "stopping the mock fleet"
docker compose --profile mock stop mock-sensors
sleep 5

# ── nothing was lost across the three failures ────────────────────────────────

step "asserting nothing was lost across the three failures"

# The captured-vs-archived comparison up top ran before any failure was injected.
# This is that same assertion after all three of them, and it is the one that
# holds regardless of which step a loss would be attributable to: whatever
# ChirpStack received across the whole run, the bridge has.
#
# Polled rather than slept on. The bridge is serial and acks after commit, so it
# is still draining what the broker held when the publisher stopped, and how long
# that takes depends on how much the three outages queued up behind it.
archived_after="$(events_psql "SELECT count(*) FROM event_up")"
wait_for "uplinks captured once everything settled (archive holds ${archived_after})" \
  "SELECT count(*) FROM telemetry.ingest_event WHERE event_type = 'up'" "-ge $archived_after" 180

# ── the two stores stay independent ───────────────────────────────────────────

step "asserting the event archive is unaffected"

[ "$archived_after" -ge "$archived" ] || fail "the event archive lost rows ($archived -> $archived_after)"
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"query":"query { allEventUps(first: 1) { nodes { devEui fCnt } } }"}' \
  "$EVENTS_API_URL" >/dev/null \
  || fail "the event archive's GraphQL endpoint stopped answering"
echo "[farm-e2e] the event archive still holds ${archived_after} uplink(s) and answers GraphQL"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "[farm-e2e] ================= phase-1 exit ================="
farm_psql "SELECT 'devices          ' || count(*) FROM registry.device"
farm_psql "SELECT 'readings         ' || count(*) FROM telemetry.reading"
farm_psql "SELECT 'metrics seen     ' || count(DISTINCT metric) FROM telemetry.reading"
farm_psql "SELECT 'uplinks captured ' || count(*) FROM telemetry.ingest_event WHERE event_type = 'up'"
farm_psql "SELECT 'curated devices  ' || count(*) FROM registry.device_assignment a WHERE upper_inf(a.valid_range) AND a.assigned_by NOT IN ('auto-register', 'inventory-reconcile')"
echo "[farm-e2e] ================================================"
echo "[farm-e2e] PASS"
