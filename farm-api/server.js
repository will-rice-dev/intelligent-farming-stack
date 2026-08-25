// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Intelligent Farming Foundation
//
// farmdata-api: a read-only GraphQL endpoint over the farm telemetry store.
//
// It exposes the `registry` and `telemetry` schemas of `farmdata` — devices,
// their placement history, the metric dictionary, the narrow per-metric
// readings, and the generated per-category pivot views — so apps and
// dashboards can query normalized telemetry without touching Postgres
// directly. It writes nothing: the telemetry bridge is the sole writer, and
// this connects as a role holding SELECT and nothing else.
//
// Unlike events-api, this is a small server rather than the PostGraphile CLI,
// for one reason: AGPL section 13. Anyone interacting with this over the
// network must be offered its complete source, and the stock CLI has nowhere
// to say so. Wrapping the same middleware in ~20 lines of http server buys two
// places to make that offer -- a header on every response, and a document at
// the root -- while leaving the GraphQL behavior entirely PostGraphile's.

'use strict';

const http = require('http');

// The image IS the postgraphile package (its WORKDIR holds package.json and
// build/), rather than carrying it as a dependency, so this resolves the
// package directory itself. `require('postgraphile')` would not resolve here.
const { postgraphile } = require('/postgraphile');
const { makeAddInflectorsPlugin } = require('/postgraphile/node_modules/graphile-utils');

const SOURCE_URL = 'https://github.com/intelligent-farming/intelligent-farming-stack';
const SOURCE_LICENSE = 'AGPL-3.0-or-later';

// PostGraphile's default column inflection is lodash camelCase, which discards
// every separator -- so `air_pm1_0` and `air_pm10` both become `airPm10`. Two
// columns producing one field name is not a warning: the schema fails to
// build, PostGraphile retries it forever, and the service answers nothing at
// all.
//
// These are not near-duplicates to be tidied away. PM1.0 and PM10 are
// different particulate sizes, and the metric vocabulary names them
// `air.pm1_0` and `air.pm10` because both are real measurements; the generated
// category views spell them that way, so every view carrying both hits this.
// The same flattening quietly turns `air_pm2_5` into `airPm25`, which is wrong
// about what it measures even where nothing collides.
//
// So: keep the underscore exactly where it separates two digits -- which is
// where it stands in for a decimal point -- and leave every other boundary to
// the default. `air_pm1_0` becomes `airPm1_0`, `air_pm2_5` becomes `airPm2_5`,
// `air_pm10` stays `airPm10`, and an ordinary `soil_vwc_30_cm` is untouched at
// `soilVwc30Cm`.
//
// Splitting on that boundary and camelCasing each side is what makes this
// safe. Masking the underscore first does not work: camelCase discards any
// marker that could carry it through, and re-inserting underscores afterwards
// means re-deriving the word boundaries camelCase has already spent.
const DECIMAL_UNDERSCORE = /(?<=[0-9])_(?=[0-9])/;

const preserveDecimalsPlugin = makeAddInflectorsPlugin(
  {
    column(attr) {
      return String(this._columnName(attr))
        .split(DECIMAL_UNDERSCORE)
        .map((part) => this.camelCase(part))
        .join('_');
    },
  },
  true, // replace the built-in inflector rather than adding beside it
);

const PORT = 5000;
const HOST = '0.0.0.0'; // inside the container; FARM_API_HOST_BIND decides what is published

if (!process.env.DATABASE_URL) {
  console.error('farmdata-api: DATABASE_URL is not set');
  process.exit(1);
}

const middleware = postgraphile(
  process.env.DATABASE_URL,
  // Both schemas the bridge fills. `sync` is deliberately omitted: it holds
  // export watermarks and replication heartbeats, which are bookkeeping for
  // the services themselves and not a product surface.
  ['registry', 'telemetry'],
  {
    appendPlugins: [preserveDecimalsPlugin],

    // `reading` and `ingest_event` are range-partitioned by pg_partman, and by
    // default PostGraphile introspects neither: it skips partitioned parents
    // entirely and exposes the monthly children instead. That is backwards in
    // the most damaging way available -- the fact table is missing, while
    // `allReadingP20260501S` and `allReadingDefaults` look like entities and
    // return one month, or the almost-always-empty default partition, to a
    // client that has no way to know it got a fraction of the rows. It also
    // grows the schema by a handful of types every month, forever.
    //
    // This inverts it: the parent is exposed as one table, the partitions are
    // hidden, and Postgres prunes underneath. It is the whole reason `reading`
    // is queryable here at all.
    usePartitionedParent: true,

    // ── read-only posture ────────────────────────────────────────────────
    disableDefaultMutations: true, // no create/update/delete fields in the schema
    ignoreRbac: false, // honor the connecting role's GRANTs (SELECT only)
    // The generated category pivot views carry no indexes at all — they are
    // views over `reading`/`reading_latest` — so without this they would
    // expose no orderBy or condition arguments and be nearly unqueryable.
    // At bench volumes the unindexed scans are fine.
    ignoreIndexes: true,

    // ── client ergonomics ────────────────────────────────────────────────
    enableCors: true, // the library spelling of the CLI's --cors
    dynamicJson: true, // jsonb (device meta, event details) <-> GraphQL JSON
    enableQueryBatching: true,
    legacyRelations: 'omit',
    setofFunctionsContainNulls: false,

    // ── operational ──────────────────────────────────────────────────────
    // The schema is owned by the migration chain and changes only when
    // farmdata-migrate runs, which happens before this service starts.
    watchPg: false,
    retryOnInitFail: true, // tolerate the database still finishing init
    extendedErrors: ['errcode'], // errcode only — no detail/hint leakage
    bodySizeLimit: '100kB',

    // ── GraphiQL IDE (bench convenience; turn OFF on any exposed deployment) ──
    graphiql: process.env.API_GRAPHIQL === 'true',
    enhanceGraphiql: true,
  },
);

const sourceDocument = JSON.stringify(
  {
    name: 'farmdata-api',
    description: 'Read-only GraphQL over the farm telemetry store',
    license: SOURCE_LICENSE,
    source: SOURCE_URL,
    endpoints: {
      graphql: '/graphql',
      graphiql: process.env.API_GRAPHIQL === 'true' ? '/graphiql' : null,
    },
  },
  null,
  2,
);

const server = http.createServer((req, res) => {
  // On every response, including GraphQL results, GraphiQL, and errors: the
  // offer has to be reachable from wherever a user actually interacts with
  // this, not only from a page they might never load.
  res.setHeader('x-source', SOURCE_URL);
  res.setHeader('x-license', SOURCE_LICENSE);

  const path = (req.url || '').split('?')[0];
  if (req.method === 'GET' && (path === '/' || path === '/source')) {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    res.end(sourceDocument + '\n');
    return;
  }

  middleware(req, res);
});

server.listen(PORT, HOST, () => {
  console.log(`farmdata-api: listening on ${HOST}:${PORT}`);
  console.log(`farmdata-api: source available at ${SOURCE_URL}`);
  if (process.env.API_GRAPHIQL === 'true') {
    console.log('farmdata-api: GraphiQL is enabled -- disable it on any exposed deployment');
  }
});

// Compose sends SIGTERM on `down`/`stop`. Without a handler the default is an
// immediate exit, which drops whatever request is in flight; there is nothing
// to lose on a read path, but stopping cleanly keeps the shutdown quiet in the
// log rather than looking like a crash.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    console.log(`farmdata-api: ${signal} received, shutting down`);
    server.close(() => process.exit(0));
    // A backstop: a keep-alive connection that never goes idle would otherwise
    // hold the close open until compose's grace period expires in a SIGKILL.
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
