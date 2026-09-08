# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Intelligent Farming Foundation
#
# farmdata-api: PostGraphile (MIT-licensed, AGPL-compatible) serving a
# read-only GraphQL endpoint over the farm telemetry store — the registry and
# telemetry schemas of `farmdata`, filled by the telemetry bridge.
#
# Same pinned base as events-api, but this one runs its own small server rather
# than the stock CLI entrypoint. The reason is AGPL section 13: a network
# service has to offer its complete source, and the CLI has nowhere to say so.
# server.js wraps the same middleware and adds that offer — a header on every
# response and a document at the root — without changing any GraphQL behavior.

FROM graphile/postgraphile:4.14.0

# Keep the image's own WORKDIR: it *is* the postgraphile package (package.json,
# build/, node_modules/ all live here), which is what server.js resolves
# against. Nothing is installed on top, so the image adds one file.
WORKDIR /postgraphile
COPY server.js ./farm-server.js

# Replaces the base image's `./cli.js`. The connection settings and the
# GraphiQL switch come from the environment, so no credential appears in the
# process list — the same reason events-api passes its connection through the
# environment rather than a CLI flag.
ENTRYPOINT ["node", "/postgraphile/farm-server.js"]
