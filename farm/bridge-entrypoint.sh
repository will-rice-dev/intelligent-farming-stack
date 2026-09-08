#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Intelligent Farming Foundation
#
# Wraps the telemetry-bridge daemon to hand it two things compose cannot.
#
# The ChirpStack API key is minted at run time by the provisioner and written
# only to /shared/config.json -- no environment variable carries it, because it
# does not exist until the stack is already up. The bridge's inventory
# reconciler wants it as FARM_BRIDGE_CHIRPSTACK_API_KEY, so something has to
# read the file and export it. That is this script, and it is the same shape
# Leftenant's own entrypoint uses to configure itself from that volume.
#
# The property an unplaced device lands on is likewise a value with exactly one
# authoritative copy -- farm/projection.json, which farmdata-migrate seeds into
# the database. Deriving it here rather than repeating the UUID in .env.example
# means the two can never disagree; setting FARM_BRIDGE_PROPERTY_ID explicitly
# still wins, for a bench pointed at a different property.
#
# Invoked through sh by compose, so it does not depend on an executable bit
# surviving a checkout on Windows.

set -eu

CONFIG=/shared/config.json
SEED=/seed/projection.json

# `maintain` is handed straight through, before anything below runs.
#
# It is the one subcommand that touches nothing this script supplies: it opens
# a database connection with FARM_BRIDGE_MAINT_LOGIN_USER, runs pg_partman
# maintenance, asserts the outcome and exits. No broker, no ChirpStack REST
# call, no default property. Yet without this it would sit through the wait
# below and then fail -- for a whole minute, then exit 1, because a
# *provisioner* has not run.
#
# That matters because of when this command is typed. It is the by-hand
# recovery path and the monitor's probe: `docker compose run --rm --no-deps
# telemetry-bridge maintain`, with `--no-deps` precisely so nothing else has
# to be up. Its exit code is the verdict -- 0 healthy, 2 a set is degraded, 1
# the run could not happen -- and a 1 earned here would be a 1 about the
# shared volume wearing the clothes of a 1 about the database, on the one path
# that only ever runs when something is already wrong.
#
# `reconcile` and `curation-lag` are deliberately not short-circuited:
# reconcile needs the API key this script reads, and curation-lag resolves the
# full bridge config, which requires the default property derived below.
if [ "${1:-}" = "maintain" ]; then
  exec node /app/dist/cli.js "$@"
fi

# The provisioner is gated on with `service_completed_successfully`, so the file
# is normally already there. The wait covers the case that ordering cannot: a
# `shared` volume recreated under a provisioner container that compose considers
# already complete.
attempt=0
while [ ! -f "$CONFIG" ] && [ "$attempt" -lt 30 ]; do
  attempt=$((attempt + 1))
  sleep 2
done

if [ ! -f "$CONFIG" ]; then
  echo "bridge-entrypoint: $CONFIG never appeared -- has the provisioner run?" >&2
  exit 1
fi

# node is what this image has; it is also the only parser that will read the
# provisioner's JSON exactly as the provisioner wrote it. A failure here is
# fatal rather than silent: running with reconciliation quietly off would look
# like a working bridge that never mirrors a device.
read_json_field() {
  node -e '
    const fs = require("fs");
    const [file, field] = process.argv.slice(1);
    const value = JSON.parse(fs.readFileSync(file, "utf8"))[field];
    if (typeof value !== "string" || value === "") {
      throw new Error(`${file} has no usable "${field}"`);
    }
    process.stdout.write(value);
  ' "$1" "$2"
}

FARM_BRIDGE_CHIRPSTACK_API_KEY="$(read_json_field "$CONFIG" apiKey)"
FARM_BRIDGE_CHIRPSTACK_TENANT_ID="$(read_json_field "$CONFIG" tenantId)"
export FARM_BRIDGE_CHIRPSTACK_API_KEY FARM_BRIDGE_CHIRPSTACK_TENANT_ID

if [ -z "${FARM_BRIDGE_PROPERTY_ID:-}" ]; then
  if [ ! -f "$SEED" ]; then
    echo "bridge-entrypoint: FARM_BRIDGE_PROPERTY_ID is unset and $SEED is not mounted" >&2
    exit 1
  fi
  FARM_BRIDGE_PROPERTY_ID="$(read_json_field "$SEED" default_property_id)"
  export FARM_BRIDGE_PROPERTY_ID
  echo "bridge-entrypoint: using the seed's default property ${FARM_BRIDGE_PROPERTY_ID}"
fi

# exec, so the daemon is PID 1 and receives SIGTERM directly -- without it a
# shutdown would have to wait out compose's grace period and end in SIGKILL,
# discarding the message the bridge was mid-commit on.
exec node /app/dist/cli.js "$@"
