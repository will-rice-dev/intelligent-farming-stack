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
    // Deliberately no `enableCors`. It is the library spelling of the CLI's
    // --cors, and it answers `Access-Control-Allow-Origin: *` -- which would
    // hand every page the operator's browser happens to load a readable view
    // of every reading on the box. See the same-origin guard below.
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

/**
 * True for a request some *other* page's browser sent here.
 *
 * This API has no authentication: what keeps it private is the loopback bind,
 * and a browser running on the operator's own machine is already inside it --
 * that bind stops the LAN, not the page in front of them. Without a guard,
 * any page they visit could read every reading and every device off
 * 127.0.0.1.
 *
 * Dropping `enableCors` is most of the answer -- with no
 * `Access-Control-Allow-Origin`, a cross-origin page cannot read the response
 * -- but not all of it. PostGraphile mounts a urlencoded body parser beside
 * the JSON one, and `application/x-www-form-urlencoded` is a CORS-simple
 * content type, so a hostile page can POST `query=...` with no preflight and
 * have it *executed*: a connection taken and a query run, blind, as fast as
 * it cares to. Refusing the request is what stops that.
 *
 * The telemetry bridge's curation API refuses anything carrying an `Origin`
 * at all, and can, because no browser is among its callers. This one ships
 * GraphiQL, and browsers attach `Origin` to same-origin POSTs too -- so a
 * blanket refusal would 403 GraphiQL against its own server. Hence the
 * comparison: `Origin`'s host against the `Host` we were asked for. Real
 * callers lose nothing -- curl and server-side clients send no `Origin`, and
 * GraphiQL sends one that matches.
 *
 * An unparseable `Origin` is refused, which is the right answer for the
 * literal `null` a sandboxed iframe or a `file://` page sends: opaque origin,
 * no legitimate business here.
 *
 * Note what this does not stop: DNS rebinding. A page whose name resolves to
 * this address is same-origin as far as the browser is concerned, and nothing
 * here checks `Host` against an allowlist. Browsers' own local-network
 * restrictions are the mitigation; the README says so rather than pretending
 * otherwise.
 */
function isCrossOriginRequest(req) {
  const origin = req.headers.origin;
  if (typeof origin !== 'string' || origin.length === 0) {
    return false; // not a browser, or a navigation -- nothing to refuse
  }
  const host = req.headers.host;
  if (typeof host !== 'string' || host.length === 0) {
    return true; // an Origin with no Host to compare it to: refuse
  }
  try {
    return new URL(origin).host !== host;
  } catch {
    return true; // including `Origin: null`
  }
}

const server = http.createServer((req, res) => {
  // On every response, including GraphQL results, GraphiQL, and errors: the
  // offer has to be reachable from wherever a user actually interacts with
  // this, not only from a page they might never load.
  res.setHeader('x-source', SOURCE_URL);
  res.setHeader('x-license', SOURCE_LICENSE);

  // Before routing, so it covers GraphQL, GraphiQL, and the source document
  // alike -- and after the headers above, so even the refusal carries the
  // section 13 offer. A person opening this in a browser navigates to it and
  // sends no `Origin`, so the offer stays reachable the way it is meant to be.
  if (isCrossOriginRequest(req)) {
    res.writeHead(403, { 'content-type': 'application/json; charset=utf-8' });
    res.end(
      JSON.stringify({
        errors: [{ message: 'This API does not serve cross-origin browser requests.' }],
      }) + '\n',
    );
    return;
  }

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
