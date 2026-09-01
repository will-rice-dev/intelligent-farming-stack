#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Intelligent Farming Foundation
#
# End-to-end proof of the farm telemetry path: a mock sensor's uplink through
# ChirpStack and mosquitto into the telemetry bridge, landing as normalized,
# property-stamped readings in farmdata, queryable over GraphQL, with a device
# curated through the curation API and the curation-lag alarm asserted by its
# exit code. Then the same path put under seven failures it has to survive --
# three in the consumer and its database, three in the broker holding the queue
# that the first three depend on, and one that breaks everything at once.
#
# Then bad data, which is the other half of what a farm sends: a poison message
# in the middle of an offline backlog (the one that matters -- an unacked poison
# does not lose a message, it wedges the queue and stops the farm), timestamps a
# decoder should never emit, a redelivery observed rather than inferred, and a
# device whose codec throws. Those steps read the daemon's own counter report,
# which is the only place some of it is visible: a message dropped deliberately
# leaves no row, and a redelivery that was deduped leaves exactly the rows one
# that never happened would.
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
# Which is also why no count carries a per-failure recovery assertion here.
# The mock fleet publishes throughout, so any bar taken from a snapshot -- the
# bridge's own prior count or the archive's -- is met by the next few uplink
# rounds with everything the outage held silently discarded. The recoveries are
# asserted by *identity* instead: the set of uplink ids the archive held when
# the failure ended, every one of which has to reach farmdata. Fresh uplinks
# are not in that set and so cannot satisfy it. Do not reduce those back to a
# comparison of counts, in either direction.
#
# The three broker failures need one more thing said about them. Nothing is
# published *through* a broker that is down: the gateway bridges reach ChirpStack
# over mosquitto too, so while it is stopped ChirpStack receives nothing and
# archives nothing, and both stores go quiet together. That is what keeps the
# comparison honest across a broker outage -- an uplink lost in that window is
# missing from both sides of it, exactly like a dropped datagram. What a broker
# outage can genuinely cost is the backlog it was already holding, and those
# uplinks *are* in the archive, because ChirpStack wrote them there before the
# broker died. So the set frozen before a broker step is precisely the set at
# risk, and a lost queue shows up as a named, attributable failure.
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
  # An empty body is a failure, not a pass, and it has to be said explicitly.
  # Every caller passes `$(graphql ...)`, which is `curl -fsS` -- and a command
  # substitution that fails inside an *argument* does not trip errexit: bash
  # discards its status and the function is simply handed "". Without this line
  # an endpoint refusing connections outright reaches the grep below with
  # nothing to match and is reported ok, which is exactly backwards for the one
  # caller that exists to prove a service came back.
  [ -n "$response" ] || fail "${label}: no response at all -- the endpoint did not answer"
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

# Wait until farmdata-api answers a real query again. A bounded retry rather
# than a single curl on purpose: this service has no retry loop of its own --
# it takes the connection error, exits, and comes back because it carries
# `restart: unless-stopped` -- so it is legitimately unreachable for a few
# seconds after the database returns, and Docker's restart backoff decides for
# how many.
#
# It asserts the response body, not the port. With retryOnInitFail the process
# stays up and listening while PostGraphile retries introspection in the
# background, so a service answering nothing but errors passes any check that
# stops at a connection or a status code. `graphql` is curl -fsS, which under
# this script's `set -e` would abort rather than retry -- hence the `if`, where
# errexit is suspended.
wait_for_farm_graphql() {
  local what="$1" timeout="${2:-120}"
  local deadline=$(( $(date +%s) + timeout )) response="" last="no response at all"
  while :; do
    if response="$(graphql 'query { allReadings(first: 1) { nodes { deviceId metric } } allProperties { nodes { propertyId } } }' 2>/dev/null)"; then
      if ! printf '%s' "$response" | grep -q '"errors"'; then
        echo "[farm-e2e] $what: farmdata-api is answering GraphQL again"
        return 0
      fi
      last="$response"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "$what: farmdata-api did not answer GraphQL within ${timeout}s -- last: $last"
    sleep 2
  done
}

# Waits until the broker is accepting connections again.
#
# A restarted container is not a ready broker -- mosquitto binds its listener
# before it has finished reading back its persisted sessions, and `compose start`
# returns as soon as the container is running either way. So the probe is a
# connection, not a port. It is the same probe the service's healthcheck uses,
# run from here because these steps need to wait on it at a moment of their own
# choosing rather than only at boot.
#
# mosquitto_pub with no -i generates its own client id and connects with a clean
# session, which is the point: MQTT hands a client id to whoever connected with
# it most recently, so a probe borrowing the bridge's would evict the very
# persistent session these steps are asserting on.
wait_for_broker() {
  local what="$1" timeout="${2:-60}"
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    if docker compose exec -T mosquitto \
         mosquitto_pub -h 127.0.0.1 -p 1883 -t healthcheck/farm-e2e -m ping -q 0 >/dev/null 2>&1; then
      echo "[farm-e2e] $what: the broker is accepting connections again"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "$what: the broker did not accept a connection within ${timeout}s"
    sleep 1
  done
}

# The interval mosquitto is configured to checkpoint its session database at,
# read from the config rather than repeated here.
#
# It is the bound on what an unclean broker death may discard, and the whole
# reason the "killed outright" step below can assert no loss at all: persistence
# is a periodic checkpoint, not a journal, so with no interval set the window is
# mosquitto's 1800s default and nothing queued in the last half hour is on disk.
# A step carrying its own copy of the number would keep passing after someone
# changed the real one.
# The container id compose currently holds for a service, or empty. `ps -aq`
# rather than `ps -q` so a one-shot that has already exited is still found --
# which is the whole point here, since the one-shots are exactly what needs
# inspecting after a restart.
service_container() {
  docker compose --profile farm --profile mock ps -aq "$1" 2>/dev/null | head -1
}

# When a container last started, plus how it ended. Read as one string so a
# one-shot can be shown to have genuinely re-executed rather than been skipped:
# compose reports success either way, and the exit code alone is unchanged by a
# run that never happened.
oneshot_state() {
  local cid
  cid="$(service_container "$1")"
  [ -n "$cid" ] || fail "service $1 has no container at all -- it never ran"
  docker inspect "$cid" --format '{{.State.StartedAt}} {{.State.Status}} {{.State.ExitCode}}'
}

broker_autosave_seconds() {
  local seconds
  seconds="$(awk '/^autosave_interval[[:space:]]+[0-9]+[[:space:]]*$/ { print $2 }' mosquitto/mosquitto.conf)"
  [ -n "$seconds" ] \
    || fail "mosquitto/mosquitto.conf sets no autosave_interval, so mosquitto's 1800s default applies and an unclean broker death has no bounded cost for this step to assert"
  printf '%s' "$seconds"
}

# Every uplink id ChirpStack's archive holds right now. The two stores share a
# message identity, which is what makes a per-message comparison possible at
# all: event_up's primary key is ChirpStack's deduplicationId, and that is
# exactly what the bridge records as telemetry.ingest_event.source_event_id.
archived_uplink_ids() {
  events_psql "SELECT lower(deduplication_id::text) FROM event_up" | LC_ALL=C sort
}

# The same ids from the bridge's side. Tolerates a database that is not
# answering: these are polled across a farm-postgres restart, where an empty
# answer means "nothing captured yet", which is a reason to keep waiting rather
# than to abort the script.
captured_uplink_ids() {
  farm_psql "SELECT lower(source_event_id) FROM telemetry.ingest_event WHERE event_type = 'up'" 2>/dev/null \
    | LC_ALL=C sort || true
}

# How many ids are in a newline-separated list. `grep -c .` rather than `wc -l`
# because an empty list is one empty line to printf and zero ids to this.
id_count() {
  printf '%s\n' "$1" | grep -c . || true
}

# Wait until every uplink id in $2 (a frozen, sorted list) has been captured by
# the bridge.
#
# A count cannot carry this assertion while the fleet is publishing. The bar
# would be a snapshot of a store that keeps growing, and this wait's own
# timeout is worth several times anything an outage here can queue up -- ~23
# uplinks per MOCK_INTERVAL_SECONDS against a backlog of at most a few rounds --
# so a backlog discarded in its entirety is covered by fresh traffic and the
# step passes on it. Naming the messages takes the fleet out of the assertion:
# uplinks that are not in the set cannot satisfy the set.
wait_for_capture_of() {
  local what="$1" required="$2" timeout="${3:-180}"
  local deadline=$(( $(date +%s) + timeout )) missing=""
  while :; do
    missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$required") <(captured_uplink_ids))"
    if [ -z "$missing" ]; then
      echo "[farm-e2e] $what: every uplink the archive held has reached farmdata"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "$what: waited ${timeout}s, $(id_count "$missing") uplink(s) ChirpStack archived never reached farmdata -- e.g. $(printf '%s\n' "$missing" | head -3 | tr '\n' ' ')"
    sleep 2
  done
}

# ── the bridge's own counters ─────────────────────────────────────────────────
#
# Everything above reads rows. These read the daemon's report, which is the only
# place some of what this script now asserts is visible at all: a message the
# bridge dropped *deliberately* leaves no row to find, and a redelivery that was
# correctly deduped leaves exactly the rows a redelivery that never happened
# would. Both used to be unobservable from out here.

# The report the daemon logs on demand, as one JSON object.
#
# SIGUSR2 rather than waiting out FARM_BRIDGE_REPORT_INTERVAL_SECONDS: the
# assertions below are deltas across one injection, and a periodic tick landing
# inside the injection would straddle it. (SIGUSR2 and not SIGUSR1, which Node
# reserves for the inspector -- the daemon would open a debugger instead.)
#
# Read past a log mark, for the reason the database-outage step reads past one:
# on a reused bench the window is full of earlier reports, and matching the last
# line in the whole log would happily return one from a previous run. Captured
# into a variable and matched with a here-string rather than piped into `grep`,
# for the pipefail/EPIPE reason spelled out at the database-outage step.
#
# ONE TRAP, and it is the one to get wrong: **a bridge restart is a new process
# and every counter starts at zero.** A report taken before a step that stops,
# kills or power-cycles the bridge is not a baseline for anything after it.
bridge_report() {
  local what="$1" timeout="${2:-30}"
  local mark deadline log line
  mark="$(docker compose logs --no-color telemetry-bridge | wc -l | tr -d ' ')"
  docker compose kill -s USR2 telemetry-bridge >/dev/null 2>&1 \
    || fail "${what}: could not signal the bridge for a counter report"
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    log="$(docker compose logs --no-color telemetry-bridge | tail -n "+$((mark + 1))")"
    # The daemon's own diagnostics deliberately say "ingest reporter:", never
    # this prefix, so nothing but a real report can match here.
    line="$(sed -n 's/.*ingest report: //p' <<<"$log" | tail -1)"
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] \
      || fail "${what}: the bridge logged no ingest report within ${timeout}s of SIGUSR2 -- is FARM_BRIDGE_REPORT_INTERVAL_SECONDS reaching a daemon old enough to have the reporter?"
    sleep 1
  done
}

# One counter out of a report, by accessor path (".jsonParseFailures",
# ".writer.envelopesReplayed"). Reuses json_field, so the body is JSON.parsed
# rather than evaluated.
report_field() {
  printf '%s' "$1" | json_field "$2"
}

# assert_counter LABEL BEFORE AFTER ACCESSOR EXPECTED_DELTA
#
# Deltas rather than absolutes throughout, even where a fresh process makes the
# absolute knowable: this script reuses a running bench, so the same counters
# carry whatever earlier steps in this run already did to them, and an absolute
# would be a bar that quietly changes meaning the day a step is inserted above.
assert_counter() {
  local label="$1" before="$2" after="$3" accessor="$4" want="$5"
  local was is delta
  was="$(report_field "$before" "$accessor")"
  is="$(report_field "$after" "$accessor")"
  [ -n "$was" ] && [ -n "$is" ] \
    || fail "${label}: ${accessor} is not in the bridge's report -- was=\"${was}\" is=\"${is}\""
  delta=$(( is - was ))
  [ "$delta" = "$want" ] \
    || fail "${label}: expected ${accessor} to rise by ${want}, it rose by ${delta} (${was} -> ${is})"
  echo "[farm-e2e] ${label}: ${accessor} +${delta}"
}

# The device_id the bridge minted for a DevEUI, or empty if it never made one.
#
# Through registry.device_identity rather than a column on registry.device:
# there is no dev_eui column, deliberately -- a device is one row and its
# identities are another table, so a sensor that is re-keyed keeps its history.
# The stored form is uppercase hex with no separators, which is why every
# lookup here upper()s rather than trusting the caller's spelling.
device_id_of() {
  farm_psql "SELECT device_id FROM registry.device_identity WHERE scheme = 'dev_eui' AND id_value = upper('$1')"
}

# Publish one raw message to an application event topic, as ChirpStack would.
#
# From inside the broker container, so this needs no MQTT client on the host and
# reaches mosquitto at the address its own healthcheck uses. `-s` sends stdin as
# a single message, so a payload carrying quotes and braces survives intact
# where `-m "$2"` would depend on this script's quoting all the way down.
#
# QoS 1, because that is what the bridge's subscription is and what makes the
# broker hold the message for an offline persistent session -- the whole point
# of the poison step. And no `-i`: MQTT hands a client id to whoever connected
# with it most recently, so a publisher borrowing the bridge's would evict the
# very session these steps are asserting on.
publish_app_event() {
  printf '%s' "$2" \
    | docker compose exec -T mosquitto mosquitto_pub -h 127.0.0.1 -p 1883 -q 1 -t "$1" -s \
    || fail "could not publish to $1"
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

# The bridge has to be new enough to have the ingest reporter, and this is
# where to find out rather than two-thirds of the way through the run.
#
# It is not a cosmetic version check. Node's default disposition for SIGUSR2 is
# to *terminate*, so a daemon built before the reporter landed does not ignore
# the counter request further down -- it dies on it, and every step after that
# fails for a reason with nothing to do with what it was testing. Checked once,
# here, with the fix in the message.
step "checking the bridge reports its counters"
bridge_boot_log="$(docker compose logs --no-color telemetry-bridge)"
grep -q 'ingest reporter:' <<<"$bridge_boot_log" \
  || fail "the running telemetry-bridge never announced its ingest reporter, so it predates the counter report this script asserts on -- and SIGUSR2 would kill it rather than being handled. Rebuild the image: (cd ../telemetry-bridge && npm run images:build), then docker compose --profile farm up -d --force-recreate telemetry-bridge"
echo "[farm-e2e] the bridge announced its ingest reporter — counters are readable"

step "starting the mock sensor fleet"
# `--build` on this first start only. Unlike the three farm images, which are
# built in a telemetry-bridge checkout and consumed by tag, mock-sensors is
# built from this repo -- and compose reuses an existing image rather than
# rebuilding it, so a checkout that changed the fleet (the broken-codec device
# below is exactly that) would otherwise run the previous build and fail a step
# for a reason that has nothing to do with the bridge. Cached after the first
# run, so this costs nothing on a warm bench.
docker compose --profile mock up -d --build mock-sensors

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
# one, which is what this catches. Compared per message rather than by count,
# so a red run names the uplinks that went missing -- and so that the shared
# identity the three recovery steps below all rest on is proved here, before
# any of them depends on it.
archived_ids="$(archived_uplink_ids)"
archived="$(id_count "$archived_ids")"
captured="$(farm_psql "SELECT count(*) FROM telemetry.ingest_event WHERE event_type = 'up'")"
echo "[farm-e2e] ChirpStack archived ${archived} uplink(s); the bridge captured ${captured}"
[ "$archived" -gt 0 ] || fail "ChirpStack archived no uplink at all -- nothing downstream of it can be asserted"
missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$archived_ids") <(captured_uplink_ids))"
[ -z "$missing" ] \
  || fail "$(id_count "$missing") uplink(s) ChirpStack archived are absent from farmdata -- messages were lost between the broker and farmdata: $(printf '%s\n' "$missing" | head -3 | tr '\n' ' ')"
echo "[farm-e2e] every uplink ChirpStack archived is in farmdata"

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

# Which uplinks ChirpStack had archived by the time the database came back,
# everything the outage queued up included -- named, not counted. Every one of
# them has to reach farmdata, which is a loss check rather than a liveness one
# and stays one with the mock fleet publishing throughout: an uplink that
# arrives after this snapshot is not in the set and so cannot stand in for one
# that was dropped, which is exactly what a count bar allows. Flake-immune for
# the same reason the cross-check above is -- a datagram that never reached
# ChirpStack is in neither store, so it is in neither side of the comparison.
required_ids="$(archived_uplink_ids)"
docker compose start farm-postgres
wait_for_capture_of "uplinks captured after the database came back (archive held $(id_count "$required_ids"))" \
  "$required_ids" 180
echo "[farm-e2e] the bridge resumed writing on its own — no restart needed"

# The bridge is not the only service whose database this step pulled out from
# under it. farmdata-api's only assertion is up top, before the outage, and
# every check below reads farmdata through psql rather than through the API --
# so a read API left dead by a database blip passes every remaining step. It
# recovers by restarting, which is a fine answer for a stateless reader, but
# that makes `restart: unless-stopped` load-bearing and nothing here proved it.
wait_for_farm_graphql "farmdata-api after the database outage" 120

step "resilience: the bridge goes away while the broker keeps receiving"

docker compose stop telemetry-bridge
# Long enough that several uplink rounds are published with nothing consuming
# them. They are held by mosquitto for the bridge's persistent session; that
# session is why the broker keeps them instead of discarding them.
sleep $(( MOCK_INTERVAL_SECONDS * 3 ))
# The whole backlog, named. This is the step where a count was weakest: a broker
# that had silently discarded the queue -- persistence off, the session gone
# clean, max_queued_messages exhausted -- reaches any snapshot count within a few
# uplink rounds, having lost every message it was holding.
#
# It is also the one step whose backlog can be measured directly, since the
# bridge is down while the database is up. Asserting it is non-empty matters:
# a step with nothing to drain proves nothing, and until now would still have
# gone green.
required_ids="$(archived_uplink_ids)"
backlog_ids="$(LC_ALL=C comm -23 <(printf '%s\n' "$required_ids") <(captured_uplink_ids))"
backlog="$(id_count "$backlog_ids")"
[ "$backlog" -gt 0 ] \
  || fail "the broker was handed nothing to hold -- no uplink was archived while the bridge was down, so this step would prove nothing"
echo "[farm-e2e] the broker is holding ${backlog} uplink(s) with nothing consuming them"
docker compose start telemetry-bridge
wait_for_capture_of "backlog drained after the bridge came back (${backlog} uplink(s) queued behind it)" \
  "$required_ids" 180
echo "[farm-e2e] the broker held the backlog and the bridge drained it"

step "resilience: the bridge is killed outright"

# SIGKILL, so no shutdown path runs at all: whatever was mid-write is
# abandoned without acknowledgment and the broker still holds it.
#
# The `start` below is what brings it back, not the restart policy. Verified,
# because the comment here used to say the opposite: `restart: unless-stopped`
# covers a process that dies on its own -- a crash, an OOM kill -- but Docker
# records a kill through its API as a manual stop, so an API-killed container
# stays exited with RestartCount 0 however long you wait. The policy is what
# recovers farmdata-api during the database outage above, which exits itself;
# it is not what recovers anything a `compose kill` here takes down.
docker compose kill -s KILL telemetry-bridge
sleep "$MOCK_INTERVAL_SECONDS"
# Taken after the sleep but before the `start`, so it covers what was abandoned
# mid-write as well as what was published while nothing was consuming. If
# Docker's restart policy already brought the bridge back and it is draining by
# now, this is simply a set it has partly caught up with -- still the one it has
# to arrive at. That same restart is why the backlog is not asserted non-empty
# here the way it is in the step above: the bridge may legitimately have drained
# it before this line runs.
required_ids="$(archived_uplink_ids)"
docker compose start telemetry-bridge
wait_for_capture_of "uplinks captured after a SIGKILL (archive held $(id_count "$required_ids"))" \
  "$required_ids" 180

# A guard on the schema, not an assertion about the bridge, and worth being
# plain about which: `(device_id, metric, channel, measured_at)` *is*
# telemetry.reading's primary key, so this query returns nothing whether or not
# a single message was ever redelivered. What it would catch is a migration
# that widened or dropped that key, which would take the whole idempotency
# contract with it -- and this is the cheapest place that would notice.
#
# Whether the redelivery itself replayed clean is not observable from out here
# at all. Every trace of one is collapsed by a primary key -- reading,
# reading_latest, ingest_event and device_event all dedupe on conflict -- and
# the daemon logs connection lifecycle, faults and shutdown but never its
# counters, so no query and no log line here can tell a replay that was deduped
# from a redelivery that never happened. Successful idempotence is silent by
# construction. That assertion belongs where the counters can be read: the
# telemetry-bridge repo's own db:exercise:resilience drives the consumer
# in-process, kills it in the window between a commit and that message's PUBACK,
# and asserts the redelivery lands envelopesReplayed 1 / readingsInserted 0.
dupes="$(farm_psql "SELECT count(*) FROM (SELECT device_id, metric, channel, measured_at FROM telemetry.reading GROUP BY 1,2,3,4 HAVING count(*) > 1) d")"
[ "$dupes" = "0" ] || fail "$dupes reading key(s) appear more than once -- telemetry.reading's primary key is no longer enforcing idempotency"
echo "[farm-e2e] the reading key is still unique — the constraint idempotency rests on is intact"

# ── resilience, the broker itself ─────────────────────────────────────────────
#
# The three steps above all leave mosquitto standing, which makes it the one leg
# of this that nothing had tested -- and the load-bearing one: the bridge holds
# nothing in its own process -- it acknowledges after committing and leans on the
# broker's persistent-session queue as the buffer -- so the broker's durability
# *is* the "an outage costs latency, not data" guarantee rather than a detail of
# it.
#
# Three failures, in increasing severity. The deterministic versions live in the
# telemetry-bridge repo's own db:exercise:resilience, which can read the CONNACK's
# session-present flag and the writer's counters; what these add is the packaged
# daemon meeting the same failures on the real ChirpStack path.

step "resilience: the broker restarts under a live bridge"

# The one an operator actually causes -- upgrading or restarting the broker on a
# running box. The queue is near-empty here, because the bridge is up and acking
# promptly, so what is under test is the reconnect: a client that already
# believes it is subscribed, attaching to a broker that has just come back.
log_mark="$(docker compose logs --no-color telemetry-bridge | wc -l | tr -d ' ')"

docker compose restart mosquitto
wait_for_broker "after a clean broker restart"

# Read into a variable and matched with a here-string, for the reason the
# database-outage step above spells out: `grep -q` exits at its first match, and
# with that match early in the stream `docker compose logs` takes EPIPE, exits
# 255, and pipefail returns *that*.
#
# Polled rather than read once. The bridge reconnects on its own timer, so the
# lines below arrive a second or two after the broker does.
reconnect_deadline=$(( $(date +%s) + 60 ))
while :; do
  bridge_log="$(docker compose logs --no-color telemetry-bridge | tail -n "+$((log_mark + 1))")"
  if grep -qE 'broker unreachable|reconnecting to the broker|connected to .* as "' <<<"$bridge_log"; then
    break
  fi
  [ "$(date +%s)" -lt "$reconnect_deadline" ] \
    || fail "the bridge logged nothing about the broker going away and coming back -- it did not notice"
  sleep 2
done
echo "[farm-e2e] the bridge noticed the broker restart and reconnected"

# Everything the archive holds now has to reach farmdata. Uplinks published
# while the broker was down reached neither store -- the gateway bridges publish
# through mosquitto too -- so they are on neither side of this comparison.
#
# An in-flight message delivered but not yet acknowledged when the socket died is
# redelivered on the reconnect, so this step exercises the writer's idempotency
# path as a side effect. It cannot *observe* that from out here, for the reason
# the kill step above explains, but a replay that wrote twice would break the
# primary-key guard at the end of that step.
required_ids="$(archived_uplink_ids)"
wait_for_capture_of "uplinks captured after a broker restart (archive held $(id_count "$required_ids"))" \
  "$required_ids" 180

step "resilience: the broker restarts with a backlog queued"

# Now the durability claim itself. The bridge goes away first so the broker has
# something to hold, and then the thing holding it is restarted underneath it.
docker compose stop telemetry-bridge
sleep $(( MOCK_INTERVAL_SECONDS * 3 ))

# The backlog, named -- and asserted non-empty for the same reason the
# bridge-stopped step above asserts it: bridge down with the database up is the
# one shape where the queue is directly measurable, and a step with nothing to
# drain proves nothing while still going green.
required_ids="$(archived_uplink_ids)"
backlog_ids="$(LC_ALL=C comm -23 <(printf '%s\n' "$required_ids") <(captured_uplink_ids))"
backlog="$(id_count "$backlog_ids")"
[ "$backlog" -gt 0 ] \
  || fail "the broker was handed nothing to hold -- no uplink was archived while the bridge was down, so this step would prove nothing"
echo "[farm-e2e] the broker is holding ${backlog} uplink(s) with nothing consuming them"

# `stop`, not `kill`: compose sends SIGTERM, and mosquitto's exit path is one of
# exactly three things that writes its session database to disk. That is the
# distinction the next step takes apart.
docker compose stop mosquitto
docker compose start mosquitto
wait_for_broker "after restarting the broker with a backlog queued"

docker compose start telemetry-bridge
wait_for_capture_of "backlog drained after the broker restarted (${backlog} uplink(s) queued through it)" \
  "$required_ids" 180
echo "[farm-e2e] the broker kept the backlog across its own restart"

step "resilience: the broker is killed outright"

# SIGKILL, so no shutdown path runs and nothing is flushed on the way out. What
# survives is whatever the last checkpoint caught, which is why this step waits
# for one before killing rather than killing immediately: mosquitto's persistence
# is a periodic checkpoint, not a journal.
#
# Without autosave_interval set, mosquitto's default is 1800s and this step could
# not be written at all -- the whole backlog would be inside the window and the
# assertion would be "some of it, probably". broker_autosave_seconds refuses if
# the setting is gone, so removing it fails this step rather than quietly
# widening what it tolerates.
autosave_seconds="$(broker_autosave_seconds)"

docker compose stop telemetry-bridge
sleep $(( MOCK_INTERVAL_SECONDS * 3 ))

# The publisher stops before the checkpoint wait, and that is load-bearing
# rather than tidiness. This step's own assertion only claims the set frozen
# below, so uplinks arriving during the wait would be outside it -- but the
# settled check at the end of the run claims the *whole* archive, and an uplink
# archived after the last checkpoint tick dies unsaved in the SIGKILL. Left
# publishing, this step would silently stake the run's strongest assertion on
# where the autosave clock happened to be when the kill landed: a burst inside
# the gap turns the bench red, and stays red on every later run until `down -v`,
# because a lost uplink is lost for good. Whether that happens depends on the
# tick phase, which the previous step's broker restart re-phases -- so it is
# incidental timing, not something the step controls. With the fleet stopped,
# nothing can enter the residual window and both assertions are sound. It comes
# back once the broker does, since the recovery check below needs traffic.
docker compose --profile mock stop mock-sensors
sleep 5

required_ids="$(archived_uplink_ids)"
backlog_ids="$(LC_ALL=C comm -23 <(printf '%s\n' "$required_ids") <(captured_uplink_ids))"
backlog="$(id_count "$backlog_ids")"
[ "$backlog" -gt 0 ] \
  || fail "the broker was handed nothing to hold -- no uplink was archived while the bridge was down, so this step would prove nothing"
echo "[farm-e2e] the broker is holding ${backlog} uplink(s); waiting ${autosave_seconds}s for it to checkpoint them"

# The scope of the guarantee, made executable. With the publisher stopped, the
# archive is now fixed, and after one full interval a checkpoint has certainly
# covered every id in it -- so the kill below is a kill of a broker that had time
# to checkpoint, which is exactly the case the guarantee is scoped to. The
# residual window it does *not* cover -- an uplink queued after the last tick --
# is real and is what the wait exists to stay out of; it is stated in
# mosquitto.conf and in the README rather than asserted here, because a bench
# cannot destroy an uplink without failing its own end-of-run comparison for good.
sleep $(( autosave_seconds + 10 ))

# The precondition everything above rests on, asserted rather than assumed:
# nothing entered the residual window while we waited. A count is the right
# shape here -- the archive only ever grows, so an unchanged count *is* an
# unchanged set -- and this is a guard on the fixture, not one of the
# per-message recovery bars the header rules out reducing to counts.
#
# What it catches is a future edit that leaves the fleet publishing, or restarts
# it too early: the failure would otherwise surface as the end-of-run comparison
# going permanently red on a bench nobody can un-poison, several steps away from
# the cause. Here it names the cause.
archived_at_kill="$(id_count "$(archived_uplink_ids)")"
[ "$archived_at_kill" = "$(id_count "$required_ids")" ] \
  || fail "the archive grew from $(id_count "$required_ids") to ${archived_at_kill} during the checkpoint wait -- those uplinks are inside the residual window and the kill below would destroy them for good"

docker compose kill -s KILL mosquitto
# And `start` is what brings it back -- the restart policy does not, for the
# reason spelled out in the bridge-kill step above. wait_for_broker is still the
# gate on the rest of the step, since a started container is not a ready broker.
docker compose start mosquitto
wait_for_broker "after the broker was killed outright"

# The publisher comes back before the consumer does, so there is fresh traffic
# for the publish-path check below and a little more queued behind the bridge.
docker compose --profile mock up -d mock-sensors

docker compose start telemetry-bridge
wait_for_capture_of "backlog survived an unclean broker death (${backlog} uplink(s) checkpointed before the kill)" \
  "$required_ids" 180
echo "[farm-e2e] a checkpointed backlog survived the broker being killed outright"

# And the publisher side came back too, which none of the assertions above can
# show. Everything they compare was archived *before* the broker died, so a
# ChirpStack or gateway bridge that never reconnected to the new broker would
# leave both stores frozen at the same contents and every check would still pass
# -- including the settled one at the end, which compares the two stores to each
# other rather than to a moving fleet.
#
# So this waits for the archive to *grow*: a fresh uplink getting all the way
# from a mock sensor through the gateway bridge, the restarted broker, and
# ChirpStack into the archive. Generous, because it needs a cold fleet container
# to boot and re-provision, a whole uplink round, and every hop's own reconnect
# backoff. The bar is exact rather than a floor guess: the fleet was stopped when
# the set was frozen, so the archive was fixed at that count and any growth at
# all is a new uplink.
archived_before_recovery="$(id_count "$required_ids")"
growth_deadline=$(( $(date +%s) + MOCK_INTERVAL_SECONDS * 6 + 60 ))
while :; do
  archived_now="$(id_count "$(archived_uplink_ids)")"
  if [ "$archived_now" -gt "$archived_before_recovery" ]; then
    echo "[farm-e2e] the whole publish path recovered — the archive grew ${archived_before_recovery} → ${archived_now}"
    break
  fi
  [ "$(date +%s)" -lt "$growth_deadline" ] \
    || fail "no uplink reached the archive after the broker was killed (still ${archived_now}) -- the gateway bridge or ChirpStack never reconnected to it"
  sleep 3
done

# ── failure 7: the whole box power-cycles ─────────────────────────────────────
#
# The six above each break one thing. A power blip at 3am breaks all of them at
# once, and "each recovery works" is a different claim from "they compose".
# Four things only a simultaneous restart reaches:
#
#   - `docker compose restart` keeps dependency *ordering* and drops every
#     depends_on *condition* -- those gate `up`, not `restart`. So the bridge
#     loses its `mosquitto: service_healthy` gate and farmdata-api loses both
#     of its, which is exactly what a Docker daemon coming back after a power
#     cut does to them.
#   - farmdata-api races farm-postgres. PostGraphile introspects at boot with
#     watchPg off, so losing that race is not a slow start, it is a server
#     answering errors until something restarts it.
#   - the three one-shots re-run. `restart: "no"` is a policy, not a shield
#     against an explicit restart, and their idempotency is asserted in prose
#     and nowhere else. A provisioner that re-minted the tenant API key instead
#     of reusing it would strand the bridge's reconciler on a stale credential
#     with nothing failing loudly.
#   - the whole publish chain re-forms at once: redis, chirpstack-postgres,
#     ChirpStack, the gateway bridge and the broker, in no particular order.
#
# The fleet is stopped and allowed to settle first, and that is load-bearing
# rather than cautious. ChirpStack dispatches its integrations concurrently
# (futures::future::join_all), so the MQTT publish and the PostgreSQL archive
# write race each other for any uplink it is handling -- and mosquitto is going
# down in the same window. An uplink can therefore land in event_up with its
# publish refused and never retried, which is an id the archive holds forever
# and farmdata never receives: the end-of-run comparison then goes permanently
# red on a bench nobody can un-poison. Nothing downstream can fix that, because
# the two integrations are not transactional with each other -- so it is a scope
# limit on the guarantee (it starts at the broker, not at ChirpStack) rather
# than a thing to assert. Same precondition, same reason, as the killed-broker
# step above.
#
# What makes the bar mean anything is the backlog: with the fleet quiet and the
# bridge caught up, every id is already in farmdata and wait_for_capture_of
# would pass instantly having proved nothing. So the bridge is stopped for a few
# uplink rounds first, the way failures 2, 5 and 6 do it, and the frozen set is
# genuinely at risk.

step "FAILURE 7 -- the whole box power-cycles, everything at once"

# Read out-of-band: nothing needs to be running for this, which matters because
# the bridge is about to be stopped. `--entrypoint cat` bypasses
# farm/bridge-entrypoint.sh, and `run` inherits the service's shared:ro mount.
key_before="$(docker compose run --rm --no-deps -T --entrypoint cat telemetry-bridge /shared/config.json | json_field '.apiKey')"
[ -n "$key_before" ] || fail "could not read the tenant API key out of /shared/config.json"

provisioner_before="$(oneshot_state provisioner)"
schema_wait_before="$(oneshot_state events-schema-wait)"
migrate_before="$(oneshot_state farmdata-migrate)"
echo "[farm-e2e] one-shots before the cycle: provisioner [${provisioner_before}], events-schema-wait [${schema_wait_before}], farmdata-migrate [${migrate_before}]"

# Give the broker something to hold across the cycle.
docker compose stop telemetry-bridge
sleep $(( MOCK_INTERVAL_SECONDS * 3 ))

# Then quiesce the publisher, for the join_all reason above.
docker compose --profile mock stop mock-sensors
sleep 5

log_mark="$(docker compose logs --no-color telemetry-bridge | wc -l | tr -d ' ')"

required_ids="$(archived_uplink_ids)"
backlog_ids="$(LC_ALL=C comm -23 <(printf '%s\n' "$required_ids") <(captured_uplink_ids))"
backlog="$(id_count "$backlog_ids")"
[ "$backlog" -gt 0 ] \
  || fail "nothing was queued behind the bridge, so a power cycle here would prove nothing -- the frozen set is already in farmdata"
echo "[farm-e2e] ${backlog} uplink(s) queued behind the stopped bridge; power-cycling the box under them"

# The one line this step is about. An explicit list rather than a bare
# `restart`: leftenant and the basicstation bridge are never booted by this
# script, and a bare restart's behavior over a service with no container is not
# a thing to depend on. The one-shots are named deliberately -- their re-run is
# one of the four claims.
#
# `restart`, not `down`/`up`. It is the only one of the two that drops the
# depends_on conditions, which is the point; it is what a daemon restart after a
# power cut looks like; and it keeps the container logs, so the log_mark
# arithmetic below still works -- `down` discards them with the container.
CYCLE_SERVICES="$SERVICES provisioner events-schema-wait farmdata-migrate mock-sensors"
# shellcheck disable=SC2086
docker compose --profile farm --profile mock restart -t 30 $CYCLE_SERVICES

wait_for_broker "after the whole box power-cycled"

# The bridge noticed and came back. Polled rather than read once after a sleep,
# like the clean-broker-restart step: the bridge reconnects on its own timer and
# is starting cold against peers that are themselves still coming up. Read into
# a variable and matched with a here-string -- never `logs | grep -q`, which
# takes compose's EPIPE and fails the step on the match it found.
reconnect_deadline=$(( $(date +%s) + 180 ))
while :; do
  bridge_log="$(docker compose logs --no-color telemetry-bridge | tail -n "+$((log_mark + 1))")"
  if grep -qE 'broker unreachable|reconnecting to the broker|connected to .* as "|writer session: connect attempt|writer session: connection error' <<<"$bridge_log"; then
    break
  fi
  [ "$(date +%s)" -lt "$reconnect_deadline" ] \
    || fail "the bridge logged nothing about connecting after the power cycle -- it never came back"
  sleep 2
done
echo "[farm-e2e] the bridge came back and reported it"

wait_for_capture_of "backlog survived a whole-box power cycle (${backlog} uplink(s) queued through it)" \
  "$required_ids" 240

# The publish chain re-formed, which nothing above can show: everything compared
# so far was archived before the cycle, so a ChirpStack or gateway bridge that
# never reconnected would leave both stores frozen at identical contents and
# every check would still pass. Same growth poll, same reasoning, as the
# killed-broker step -- and here it additionally covers redis and
# chirpstack-postgres, which no other failure in this script touches.
archived_before_recovery="$(id_count "$required_ids")"
growth_deadline=$(( $(date +%s) + MOCK_INTERVAL_SECONDS * 6 + 120 ))
while :; do
  archived_now="$(id_count "$(archived_uplink_ids)")"
  if [ "$archived_now" -gt "$archived_before_recovery" ]; then
    echo "[farm-e2e] the whole publish path recovered — the archive grew ${archived_before_recovery} → ${archived_now}"
    break
  fi
  [ "$(date +%s)" -lt "$growth_deadline" ] \
    || fail "no uplink reached the archive after the power cycle (still ${archived_now}) -- redis, chirpstack-postgres, ChirpStack or the gateway bridge never came back"
  sleep 3
done

# farmdata-api won its race with farm-postgres, or was restarted until it did.
wait_for_farm_graphql "after the whole box power-cycled" 180

# Each one-shot re-ran, and re-ran cleanly. StartedAt is what says it re-ran at
# all -- the status and exit code of a container that was skipped are identical
# to those of one that succeeded, so without this the check would pass over a
# compose version that quietly left them alone.
for pair in "provisioner:$provisioner_before" "events-schema-wait:$schema_wait_before" "farmdata-migrate:$migrate_before"; do
  svc="${pair%%:*}"
  was="${pair#*:}"
  now="$(oneshot_state "$svc")"
  [ "$now" != "$was" ] \
    || fail "$svc did not re-run across the power cycle (still [${now}]) -- its idempotency is asserted nowhere else, so this step is the only thing exercising it"
  [ "$(printf '%s' "$now" | awk '{print $2, $3}')" = "exited 0" ] \
    || fail "$svc re-ran and did not exit 0: [${now}]"
  echo "[farm-e2e] ${svc} re-ran as a no-op and exited 0"
done

# And the provisioner reused the tenant API key rather than minting a new one.
# A re-mint is the failure with no symptom: the token is only returned at
# creation, so the running bridge would keep the old one and every reconcile
# sweep would 401 while ingest carried on looking healthy.
key_after="$(docker compose run --rm --no-deps -T --entrypoint cat telemetry-bridge /shared/config.json | json_field '.apiKey')"
[ "$key_after" = "$key_before" ] \
  || fail "the provisioner minted a new tenant API key across the cycle -- the running bridge still holds the old one and its reconciler is on a dead credential"
echo "[farm-e2e] the provisioner reused the existing tenant API key"

# Operator curation survived the cycle, farmdata-migrate's re-run included.
# Nothing else here asserts that a re-applied migration chain leaves a person's
# placement alone, and a seeder that reached into an open assignment would look
# exactly like a healthy run from every other angle.
curated_after="$(farm_psql "SELECT count(*) FROM registry.device_assignment WHERE device_id = '${device_id}' AND upper_inf(valid_range) AND assigned_by = 'farm-e2e-operator'")"
[ "$curated_after" = "1" ] \
  || fail "the operator's open placement on ${device_id} did not survive the power cycle (found ${curated_after}, wanted 1)"
still_listed_after="$(curation_get '/v1/devices?needsCuration=true' | json_field ".devices.filter(d=>d.deviceId==='${device_id}').length")"
[ "$still_listed_after" = "0" ] || fail "the curated device came back onto the worklist after the power cycle"
echo "[farm-e2e] the curated placement survived, and the device is still off the worklist"

# A power cycle is where redelivery happens, so the key that makes a redelivery
# a no-op is worth re-asserting here. A schema guard rather than a bridge
# assertion, exactly as in the bridge-kill step: it returns nothing whether or
# not anything replayed, and what it catches is a migration widening or dropping
# telemetry.reading's primary key.
dupes="$(farm_psql "SELECT count(*) FROM (SELECT device_id, metric, channel, measured_at FROM telemetry.reading GROUP BY 1,2,3,4 HAVING count(*) > 1) d")"
[ "$dupes" = "0" ] || fail "$dupes reading key(s) appear more than once -- telemetry.reading's primary key is no longer enforcing idempotency"
echo "[farm-e2e] no reading key appears twice — idempotency survived the cycle"

# ── malformed data through the real pipe ─────────────────────────────────────
#
# The seven failures above each break a *component*. These break the *data*,
# which is the other half of what a farm sends and the half this bench has
# never seen: the adapter's malformed shapes are covered in-process by the
# telemetry-bridge repo's db:exercise:adapter, and nothing here ever put one
# through ChirpStack, mosquitto and the packaged daemon.
#
# One of them matters more than the rest. The bridge is serial and acks only
# after committing, so a message it fails to ack stays at the head of the
# broker's queue for this session and is redelivered forever -- and everything
# behind it waits. A poison message that is not acked therefore does not lose a
# message, it stops the farm, silently, until someone looks. That is the step
# below and it is why this section exists.
#
# Fixture identity: reserved DevEUIs in the fe0000000000000x range, which no
# mock sensor uses (they are f0000000000000xx) and no real device will. Their
# ingest_event rows carry source_event_ids that ChirpStack's archive has never
# heard of, which is harmless -- the loss comparison is `comm -23 archived
# captured`, one-directional, so an id in farmdata and not in the archive is
# invisible to it. The inventory reconciler will eventually deactivate these
# devices for the same reason (absent from a complete ChirpStack listing), which
# is also harmless: deactivation is a flag, and every assertion here reads
# ingest_event and reading.

step "malformed data: a poison message in the middle of an offline backlog"

POISON_EUI="fe00000000000001"
POISON_TOPIC="application/00000000-0000-4000-8000-00000000e2e1/device/${POISON_EUI}/event/up"

docker compose stop telemetry-bridge
# One round of real uplinks queued ahead of the poison, so the poison is
# genuinely in the *middle* of a backlog rather than at the front of it.
sleep "$MOCK_INTERVAL_SECONDS"

# Two shapes, because they fail at different places and only one of them is a
# parse error. The first never becomes JSON; the second is perfectly good JSON
# that is not a ChirpStack event, so it gets as far as the mapper and is
# refused for having no deviceInfo. Both are pure functions of the bytes, which
# is exactly why the adapter acks them: a redelivery cannot fix content, so
# withholding the ack would wedge this queue forever.
publish_app_event "$POISON_TOPIC" 'this is not json at all {'
publish_app_event "$POISON_TOPIC" '{"hello":"world"}'
echo "[farm-e2e] two poison messages published into the backlog"

# And more real uplinks behind them. This is the half that catches a wedge:
# with nothing queued after the poison, a queue stuck on it would still look
# drained.
sleep $(( MOCK_INTERVAL_SECONDS * 2 ))

required_ids="$(archived_uplink_ids)"
backlog_ids="$(LC_ALL=C comm -23 <(printf '%s\n' "$required_ids") <(captured_uplink_ids))"
backlog="$(id_count "$backlog_ids")"
[ "$backlog" -gt 0 ] \
  || fail "the broker was handed nothing to hold -- no uplink was archived while the bridge was down, so this step would prove nothing"
echo "[farm-e2e] the broker is holding ${backlog} uplink(s), with two poison messages among them"

docker compose start telemetry-bridge
# THE assertion. If either poison were left unacked it would sit at the head of
# this session's queue being redelivered, and none of the real uplinks behind it
# would ever arrive -- so this goes red naming them rather than timing out
# silently.
wait_for_capture_of "backlog drained past two poison messages (${backlog} uplink(s) queued)" \
  "$required_ids" 180
echo "[farm-e2e] the poison did not wedge the queue — everything behind it drained"

# The counters are the only place the poison itself left a trace: neither
# message produced a row, by design. Absolute rather than delta here, and only
# here: the `start` above is a new process, so these counters began at zero
# moments ago and nothing else has touched them.
poison_report="$(bridge_report "after the poison drained")"
poison_json="$(report_field "$poison_report" '.jsonParseFailures')"
poison_shape="$(report_field "$poison_report" '.droppedMissingField')"
[ "$poison_json" = "1" ] \
  || fail "expected exactly 1 jsonParseFailure in the restarted daemon, got \"$poison_json\" -- a payload that is not JSON must be counted, not silently dropped"
[ "$poison_shape" = "1" ] \
  || fail "expected exactly 1 droppedMissingField in the restarted daemon, got \"$poison_shape\" -- valid JSON that is not a ChirpStack event must be counted"
echo "[farm-e2e] both poison messages were acked and counted: jsonParseFailures=${poison_json} droppedMissingField=${poison_shape}"

# Neither poison carried a deviceInfo, so neither could name a device -- which
# means the evidence that they were discarded rather than captured is that no
# device was ever minted for the DevEUI they were addressed to.
poison_device="$(device_id_of "$POISON_EUI")"
[ -z "$poison_device" ] \
  || fail "the poison messages minted a device (${poison_device}) -- garbage must be counted and discarded, not captured"
echo "[farm-e2e] neither poison message left a row behind"

step "malformed data: timestamps a decoder should never emit"

# No restart in this step, so these are deltas against a mark taken now.
ts_before="$(bridge_report "before the bad-timestamp fixtures")"

TS_FUTURE_EUI="fe00000000000002"
TS_PAST_EUI="fe00000000000003"
FUTURE_EVENT_ID="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
HISTORY_EVENT_ID="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
NOW_ISO="$(node -e 'process.stdout.write(new Date().toISOString())')"
FUTURE_ISO="$(node -e 'process.stdout.write(new Date(Date.now() + 10 * 60 * 1000).toISOString())')"
ANCIENT_ISO="$(node -e 'process.stdout.write(new Date(Date.now() - 4 * 365 * 24 * 3600 * 1000).toISOString())')"

# A whole message ten minutes ahead. `occurred_at` is a *delivery* time and the
# raw table's partition key, so it has no legitimate reason to sit far from now:
# a row landing beyond the premade partitions goes to the kept default
# partition, and a default partition holding a row for a month refuses to give
# that month up -- creating the partition later fails, maintenance stalls, and
# the bridge's role holds no DELETE to clean it up. One discarded message with
# an impossible clock is much the cheaper loss, so the message is dropped whole:
# no reading, and no raw capture either.
publish_app_event "application/00000000-0000-4000-8000-00000000e2e1/device/${TS_FUTURE_EUI}/event/up" \
  "{\"deduplicationId\":\"${FUTURE_EVENT_ID}\",\"time\":\"${FUTURE_ISO}\",\"deviceInfo\":{\"devEui\":\"${TS_FUTURE_EUI}\",\"deviceName\":\"farm-e2e-future-clock\"},\"fPort\":1,\"fCnt\":1,\"object\":{\"battery\":3.7}}"

# And a message whose own delivery time is fine but which carries one ancient
# reading. This has to come through history[] rather than the event's own time:
# the ChirpStack adapter derives both occurred_at and measured_at from that one
# `time`, so a single bad clock costs the whole message and never one reading.
# A history entry carries its own instant, which is the only place the two can
# disagree -- and the blast radius is deliberately different there: the reading
# is dropped and the raw capture is kept.
publish_app_event "application/00000000-0000-4000-8000-00000000e2e1/device/${TS_PAST_EUI}/event/up" \
  "{\"deduplicationId\":\"${HISTORY_EVENT_ID}\",\"time\":\"${NOW_ISO}\",\"deviceInfo\":{\"devEui\":\"${TS_PAST_EUI}\",\"deviceName\":\"farm-e2e-ancient-history\"},\"fPort\":1,\"fCnt\":1,\"object\":{\"battery\":3.7,\"history\":[{\"time\":\"${ANCIENT_ISO}\",\"battery\":3.6}]}}"

# Wait on the one that is supposed to land, which also bounds the one that is
# not: the bridge is serial, so a capture for the second message proves the
# first has already been processed and decided about.
wait_for "the ancient-history message was captured" \
  "SELECT count(*) FROM telemetry.ingest_event WHERE source_event_id = '${HISTORY_EVENT_ID}'" "-ge 1" 60

future_rows="$(farm_psql "SELECT count(*) FROM telemetry.ingest_event WHERE source_event_id = '${FUTURE_EVENT_ID}'")"
[ "$future_rows" = "0" ] \
  || fail "a message timestamped 10 minutes in the future left a raw capture -- it must be dropped whole, or its occurred_at parks a row in the default partition that nothing here can remove"
# The message is refused before device resolution, so there is no device to
# hang a reading on -- which is itself the assertion.
future_device="$(device_id_of "$TS_FUTURE_EUI")"
[ -z "$future_device" ] \
  || fail "the future-clock message minted a device (${future_device}) -- it must be refused before anything is written"
echo "[farm-e2e] the future-clock message was dropped whole — no capture, no readings"

ancient_device="$(device_id_of "$TS_PAST_EUI")"
[ -n "$ancient_device" ] || fail "the ancient-history message minted no device, so its readings cannot be checked"
ancient_readings="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE device_id = '${ancient_device}' AND measured_at < now() - interval '3 years'")"
[ "$ancient_readings" = "0" ] || fail "$ancient_readings reading(s) older than the backfill bound landed"
fresh_readings="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE device_id = '${ancient_device}' AND measured_at >= now() - interval '3 years'")"
[ "$fresh_readings" -ge 1 ] \
  || fail "the ancient history entry took its message's good readings down with it -- a bad measured_at must drop that reading only"
echo "[farm-e2e] the ancient reading was dropped and its message kept — ${fresh_readings} good reading(s) landed"

ts_after="$(bridge_report "after the bad-timestamp fixtures")"
assert_counter "the future-clock message" "$ts_before" "$ts_after" '.writer.envelopesSkippedBadTimestamp' 1
# Two, not one, and the arithmetic is the assertion. A message dropped for its
# occurred_at rolls its own readings into this total as it goes -- what keeps
# the report reconcilable, since a reading that vanished with its message would
# otherwise leave no trace anywhere in the numbers. So: 1 from the future-clock
# message's single `battery` reading, going down with the message, and 1 from
# the ancient history entry, which is the only one of the two that was dropped
# *as a reading*. Asserting 1 here would be asserting that the whole-message
# drop is silent in this counter, which is exactly what it must not be.
assert_counter "the two bad timestamps" "$ts_before" "$ts_after" '.writer.readingsSkippedBadTimestamp' 2

step "malformed data: a redelivery that can actually be seen"

# The assertion this bench could not make before the daemon reported its
# counters. Every trace of a successful redelivery is collapsed by a primary
# key -- reading, reading_latest, ingest_event and device_event all dedupe on
# conflict -- so from out here a replay that was deduped and a redelivery that
# never happened produce identical rows. The kill step's duplicate-key query is
# a schema guard for exactly that reason and says so.
#
# Published twice on purpose rather than harvested from the SIGKILL step, which
# cannot carry it: the bridge drains far faster than the fleet publishes, so it
# is idle at the instant of most kills and there is frequently nothing unacked
# to redeliver. That would be a flake, not a proof.
REPLAY_EUI="fe00000000000004"
REPLAY_EVENT_ID="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
REPLAY_ISO="$(node -e 'process.stdout.write(new Date().toISOString())')"
REPLAY_MSG="{\"deduplicationId\":\"${REPLAY_EVENT_ID}\",\"time\":\"${REPLAY_ISO}\",\"deviceInfo\":{\"devEui\":\"${REPLAY_EUI}\",\"deviceName\":\"farm-e2e-replay\"},\"fPort\":1,\"fCnt\":1,\"object\":{\"battery\":3.7}}"

replay_before="$(bridge_report "before the redelivery")"
publish_app_event "application/00000000-0000-4000-8000-00000000e2e1/device/${REPLAY_EUI}/event/up" "$REPLAY_MSG"
wait_for "the first delivery was captured" \
  "SELECT count(*) FROM telemetry.ingest_event WHERE source_event_id = '${REPLAY_EVENT_ID}'" "-ge 1" 60
publish_app_event "application/00000000-0000-4000-8000-00000000e2e1/device/${REPLAY_EUI}/event/up" "$REPLAY_MSG"

# Poll the counter rather than the rows: the rows are identical either way,
# which is the whole problem this step exists to solve.
replay_deadline=$(( $(date +%s) + 60 ))
while :; do
  replay_after="$(bridge_report "after the redelivery")"
  replayed=$(( $(report_field "$replay_after" '.writer.envelopesReplayed') - $(report_field "$replay_before" '.writer.envelopesReplayed') ))
  [ "$replayed" -lt 1 ] || break
  [ "$(date +%s)" -lt "$replay_deadline" ] \
    || fail "the same message delivered twice was never counted as a replay (envelopesReplayed rose by ${replayed}) -- either it was not processed, or idempotency is being done by something other than the conflict this counter watches"
  sleep 2
done
echo "[farm-e2e] the redelivery was seen and counted: envelopesReplayed +${replayed}"

replay_rows="$(farm_psql "SELECT count(*) FROM telemetry.ingest_event WHERE source_event_id = '${REPLAY_EVENT_ID}'")"
[ "$replay_rows" = "1" ] || fail "the redelivered message left ${replay_rows} raw captures, not 1"
# One reading, from a message delivered twice. Counted on the device rather
# than as a readingsInserted delta: the mock fleet is publishing throughout, so
# that counter is rising for reasons that have nothing to do with this step.
# Keyed on this message's own instant, not on the device: the fixture publishes
# a fresh timestamp each run, so on a kept bench the device carries one reading
# per previous run and a bare count would climb past 1 for a reason that has
# nothing to do with idempotence.
replay_device="$(device_id_of "$REPLAY_EUI")"
replay_readings="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE device_id = '${replay_device}' AND measured_at = '${REPLAY_ISO}'::timestamptz")"
[ "$replay_readings" = "1" ] \
  || fail "the redelivered message left ${replay_readings} reading(s) at its own instant, not 1"
echo "[farm-e2e] and it inserted nothing the second time — idempotence, observed rather than inferred"

step "malformed data: a device whose codec fails"

# No injection: this device has been in the fleet since boot, publishing real
# bytes behind a codec that throws. What it proves is the claim everything
# downstream rests on and nothing here tested -- ingestion is never gated on
# decode. It is also the only assertion in this section that involves ChirpStack
# at all: a synthetic publish could show the bridge handling an object-less
# event, but only a real device shows that ChirpStack *publishes* one when the
# decoder raises.
BROKEN_EUI="f000000000000018"

broken_device="$(device_id_of "$BROKEN_EUI")"
[ -n "$broken_device" ] \
  || fail "the broken-codec device was never created -- a device whose payload never decodes must still be minted from its uplinks"

broken_captures="$(farm_psql "SELECT count(*) FROM telemetry.ingest_event WHERE device_id = '${broken_device}' AND event_type = 'up'")"
[ "$broken_captures" -ge 1 ] \
  || fail "no uplink from the broken-codec device reached telemetry.ingest_event -- either ChirpStack swallowed the event when its codec threw, or ingestion is gated on decode"

# Not "zero readings" -- "zero readings *from the payload*". The adapter mints
# gatewayRssi/gatewaySnr from the uplink's rxInfo whenever FARM_BRIDGE_SIGNAL_HEALTH
# is on, which is the bench default, and those come from radio metadata rather
# than from anything the codec produced. So a device with no decode still reports
# how well it was heard, which is worth having and is exactly not what this step
# is about. Asserting a flat 0 here would have been asserting the signal-health
# feature away, and it is what the first run of this step did.
broken_payload_readings="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE device_id = '${broken_device}' AND metric NOT IN ('gatewayRssi', 'gatewaySnr')")"
[ "$broken_payload_readings" = "0" ] \
  || fail "${broken_payload_readings} decoded reading(s) came from a device whose codec throws -- there is nothing to decode, so the fleet is no longer sending what this step thinks it is"
broken_signal_readings="$(farm_psql "SELECT count(*) FROM telemetry.reading WHERE device_id = '${broken_device}' AND metric IN ('gatewayRssi', 'gatewaySnr')")"
[ "$broken_signal_readings" -ge 1 ] \
  || fail "the broken-codec device produced no signal-health readings either, so its uplinks were not processed at all and the zero above proves nothing"
echo "[farm-e2e] the broken-codec device: ${broken_captures} raw capture(s), 0 decoded readings, ${broken_signal_readings} signal-health reading(s) — ingestion is not gated on decode"

# And its uplinks are in both stores, like everyone else's. The end-of-run
# comparison covers this too; saying it here is what makes a failure
# attributable to the decode path rather than to whichever step ran last.
broken_missing="$(LC_ALL=C comm -23 \
  <(events_psql "SELECT lower(deduplication_id::text) FROM event_up WHERE lower(dev_eui) = '${BROKEN_EUI}'" | LC_ALL=C sort) \
  <(captured_uplink_ids))"
[ -z "$broken_missing" ] \
  || fail "$(id_count "$broken_missing") uplink(s) from the broken-codec device are in the archive and not in farmdata"
echo "[farm-e2e] every uplink it sent reached farmdata, decoded or not"

step "stopping the mock fleet"
docker compose --profile mock stop mock-sensors
sleep 5

# ── nothing was lost across the seven failures, or the malformed data ────────

step "asserting nothing was lost across the seven failures and the bad data"

# The captured-vs-archived comparison up top ran before any failure was injected.
# This is that same assertion after all seven of them and after the malformed
# data, and it is the one that holds regardless of which step a loss would be
# attributable to: whatever ChirpStack received across the whole run, the bridge
# has. The synthetic fixtures do not disturb it -- they are in farmdata and not
# in the archive, and this comparison is one-directional.
#
# Polled rather than slept on. The bridge is serial and acks after commit, so it
# is still draining what the broker held when the publisher stopped, and how long
# that takes depends on how much the three outages queued up behind it.
#
# Per message here too. The publisher is stopped by now, so a count would have
# been sound at this one point in the script -- but only a set says *which*
# uplink is missing when this goes red, and only a set cannot be satisfied by
# the bridge having over-counted somewhere else.
archived_ids_after="$(archived_uplink_ids)"
archived_after="$(id_count "$archived_ids_after")"
wait_for_capture_of "uplinks captured once everything settled (archive holds ${archived_after})" \
  "$archived_ids_after" 180

# ── both read APIs still answer, and the two stores stay independent ──────────

step "asserting both read APIs still answer"

[ "$archived_after" -ge "$archived" ] || fail "the event archive lost rows ($archived -> $archived_after)"
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"query":"query { allEventUps(first: 1) { nodes { devEui fCnt } } }"}' \
  "$EVENTS_API_URL" >/dev/null \
  || fail "the event archive's GraphQL endpoint stopped answering"
echo "[farm-e2e] the event archive still holds ${archived_after} uplink(s) and answers GraphQL"

# The first six failures never touch events-postgres -- the broker steps starve
# it of uplinks while mosquitto is down, since ChirpStack is fed over the same
# broker, but nothing stops it and nothing takes rows away. So against those six
# the check above proves the two stores stay independent rather than that this
# one recovered.
#
# Failure 7 restarts it along with everything else, which makes the same two
# lines say more than they used to: `archived_after -ge archived` is now also
# the assertion that a power cycle cost the archive nothing, and the curl below
# that events-api came back at all. Neither needs a retry loop -- the growth
# poll inside that step already waited for a fresh uplink to reach this
# database, so by here it has been answering for a while.
#
# The farm store's API is the one that had its database pulled out from under it
# twice, so the run exits with both read surfaces proven rather than one proven
# at the start and one at the end.
assert_graphql_ok "farmdata-api once everything settled" \
  "$(graphql 'query { allReadingLatests(first: 1) { nodes { deviceId metric valueNum } } }')"

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
