// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Intelligent Farming Foundation

/**
 * Downstream observers for the e2e suite: ChirpStack's MQTT application-event
 * stream and the Postgres event store.
 *
 * Both observers have to *correlate* what they see back to the one uplink the
 * test just sent, because neither stream belongs to the test alone:
 *
 *  - The compose `mock-sensors` demo service (profile `mock`, started by
 *    `npm run stack:up`) emits from the same 24 DevEUIs every
 *    MOCK_INTERVAL_SECONDS, cycling through *all* of each sensor's vectors — the
 *    very vectors the suite sends. An uncorrelated "next event for this DevEUI"
 *    therefore very often returns a demo-loop event, not the frame just sent.
 *
 *  - `event_up` lives in the named `eventsdata` volume and `scripts/e2e.sh` tears
 *    down with `docker compose down` (no `-v`), so rows survive between runs. An
 *    uncorrelated "latest row for this DevEUI" returns the *previous* run's row on
 *    the very first poll — before ChirpStack has stored anything for this run —
 *    which makes the suite's most important assertion pass even when the uplink
 *    under test was dropped outright (bad MIC, wrong frequency, unregistered
 *    gateway).
 *
 * The correlation key is the frame counter the emitter reports, plus (for the
 * store, whose rows outlive the process) a time lower bound.
 */

import mqtt, { type MqttClient } from 'mqtt';
import { Pool } from 'pg';

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/** The decoded-uplink fields the e2e assertions read from an app event. */
export interface UplinkEvent {
  deviceInfo?: { devEui?: string };
  fPort?: number;
  fCnt?: number;
  /** US915 uplink DR index ChirpStack resolved from the gateway's `datr`. */
  dr?: number;
  /** TX params ChirpStack resolved for the frame; `frequency` is in **Hz**. */
  txInfo?: { frequency?: number };
  object?: Record<string, unknown>;
}

/**
 * ChirpStack marshals its integration events with protobuf-JSON semantics, which
 * omit any field holding its type's default value — so `fCnt: 0` and `dr: 0` are
 * simply absent from the payload rather than present as zero. A missing numeric
 * field means 0, not "unknown", so every comparison must normalize first;
 * otherwise the first frame of a run (FCnt 0) would never match its own waiter,
 * and a regression back to DR0 would read as `undefined` instead of `0`.
 */
export const eventFCnt = (evt: UplinkEvent): number => evt.fCnt ?? 0;

/** See `eventFCnt` — DR 0 is likewise omitted from ChirpStack's JSON. */
export const eventDr = (evt: UplinkEvent): number => evt.dr ?? 0;

/** Predicate picking the single uplink event a waiter is interested in. */
export type UplinkMatcher = (evt: UplinkEvent) => boolean;

/** Matcher for the event carrying a specific frame counter. */
export const byFCnt =
  (fCnt: number): UplinkMatcher =>
  (evt) =>
    eventFCnt(evt) === fCnt;

interface Waiter {
  /** Identity used to remove this waiter on timeout, since several may be live. */
  id: number;
  match: UplinkMatcher;
  settle: (evt: UplinkEvent) => void;
}

/**
 * How many still-unmatched events we keep per DevEUI. The demo loop publishes for
 * these same DevEUIs for the whole run, so an unbounded buffer would grow without
 * limit and make every `waitFor` scan an ever-longer tail of stale events. A few
 * dozen is far more than the handful of rounds a single test spans.
 */
const MAX_BUFFERED_PER_DEVICE = 50;

/**
 * Subscribes to ChirpStack's uplink app events and lets a test await the *matching*
 * event for a given DevEUI. Events that match no outstanding waiter are buffered
 * (capped), so a waiter registered just after the event arrived still finds it.
 */
export class MqttCollector {
  private client!: MqttClient;
  private readonly buffered = new Map<string, UplinkEvent[]>();
  private readonly waiters = new Map<string, Waiter[]>();
  private nextWaiterId = 1;

  async connect(url: string): Promise<void> {
    this.client = mqtt.connect(url);
    await new Promise<void>((resolve, reject) => {
      this.client.once('connect', () => resolve());
      this.client.once('error', reject);
    });
    await new Promise<void>((resolve, reject) => {
      this.client.subscribe('application/+/device/+/event/up', (err) =>
        err ? reject(err) : resolve(),
      );
    });
    this.client.on('message', (_topic, payload) => {
      let evt: UplinkEvent;
      try {
        evt = JSON.parse(payload.toString('utf8')) as UplinkEvent;
      } catch {
        return;
      }
      const eui = evt.deviceInfo?.devEui?.toLowerCase();
      if (!eui) return;

      // Hand the event to the first waiter whose predicate accepts it. Waiters
      // that don't want it stay registered: an event for a DevEUI is not
      // necessarily the event any given waiter is waiting for.
      const list = this.waiters.get(eui);
      if (list) {
        const idx = list.findIndex((w) => w.match(evt));
        if (idx >= 0) {
          const [waiter] = list.splice(idx, 1);
          if (list.length === 0) this.waiters.delete(eui);
          waiter.settle(evt);
          return;
        }
      }

      const arr = this.buffered.get(eui) ?? [];
      arr.push(evt);
      // Age out the oldest once we exceed the cap — an event that old can no
      // longer be the one a still-outstanding waiter is about to ask for.
      if (arr.length > MAX_BUFFERED_PER_DEVICE) {
        arr.splice(0, arr.length - MAX_BUFFERED_PER_DEVICE);
      }
      this.buffered.set(eui, arr);
    });
  }

  /**
   * Resolve with the uplink event for `devEui` that satisfies `match`, or reject
   * on timeout. Any number of waits may be outstanding for one DevEUI at once.
   *
   * @param description  what the wait is looking for, quoted in the timeout error.
   */
  waitFor(
    devEui: string,
    match: UplinkMatcher,
    timeoutMs: number,
    description = 'a matching uplink',
  ): Promise<UplinkEvent> {
    const eui = devEui.toLowerCase();

    // Take the event straight out of the buffer if the broker already delivered
    // it. Non-matching entries are deliberately left in place: they belong to the
    // demo loop (or to a wait yet to be registered) and consuming them blindly —
    // the old `queued.shift()` — is what made a test assert against a demo-loop
    // event carrying a different vector.
    const queued = this.buffered.get(eui);
    if (queued) {
      const idx = queued.findIndex(match);
      if (idx >= 0) {
        const [evt] = queued.splice(idx, 1);
        return Promise.resolve(evt);
      }
    }

    return new Promise<UplinkEvent>((resolve, reject) => {
      const id = this.nextWaiterId++;
      const timer = setTimeout(() => {
        this.dropWaiter(eui, id);
        reject(
          new Error(`no MQTT uplink for ${eui} matching ${description} within ${timeoutMs}ms`),
        );
      }, timeoutMs);
      // Waiters live in a list per DevEUI. Keying the map by DevEUI alone used to
      // overwrite — and so silently orphan — any earlier waiter for the same
      // device, whose timer then rejected even though its event had arrived.
      this.addWaiter(eui, {
        id,
        match,
        settle: (evt) => {
          clearTimeout(timer);
          resolve(evt);
        },
      });
    });
  }

  private addWaiter(eui: string, waiter: Waiter): void {
    const list = this.waiters.get(eui);
    if (list) list.push(waiter);
    else this.waiters.set(eui, [waiter]);
  }

  private dropWaiter(eui: string, id: number): void {
    const list = this.waiters.get(eui);
    if (!list) return;
    const idx = list.findIndex((w) => w.id === id);
    if (idx >= 0) list.splice(idx, 1);
    if (list.length === 0) this.waiters.delete(eui);
  }

  async end(): Promise<void> {
    if (this.client) await new Promise<void>((resolve) => this.client.end(false, {}, () => resolve()));
  }
}

/** The `event_up` fields the e2e assertions read back out of the store. */
export interface StoredUplink {
  fCnt: number;
  fPort: number;
  /** `event_up.dr` — the US915 DR index ChirpStack recorded for the frame. */
  dr: number;
  /** `event_up.time`, stamped by ChirpStack when it processed the uplink. */
  time: Date;
  /** `event_up.tx_info`; `frequency` is in **Hz**, same as the MQTT event. */
  txInfo: { frequency?: number } | null;
  /**
   * `event_up.object`. The column is `jsonb not null`, but a JSON `null` is a
   * legal value there — that is what a codec failure looks like — so callers get
   * it as-is and assert on it, which diffs far better than timing out.
   */
  object: Record<string, unknown> | null;
}

/**
 * One `event_up` row as node-pg hands it back. Declared as a `type` (not an
 * `interface`) because `pool.query<R>`'s constraint is pg's `QueryResultRow`,
 * i.e. an index signature, and only object *type literals* get one implicitly.
 *
 * `f_cnt` is `bigint`, which node-pg returns as a string rather than risk a lossy
 * Number — hence the explicit coercion below.
 */
type EventUpRow = {
  f_cnt: string;
  f_port: number;
  dr: number;
  time: Date;
  tx_info: { frequency?: number } | null;
  object: Record<string, unknown> | null;
};

/**
 * The event store's own clock, for use as `waitForEventUp`'s `since` bound.
 *
 * `event_up.time` is stamped by ChirpStack from its own wall clock (our rxpk
 * carries no gateway time, so ChirpStack falls back to "now"), so the bound has to
 * be read in ChirpStack's frame of reference — not the test runner's. ChirpStack
 * and events-postgres share the Docker VM's clock while the suite usually runs on
 * the host, and the two can drift far enough apart (a laptop sleep will do it) to
 * either miss our own row or admit the previous run's. Reading `now()` from the
 * store removes that skew rather than papering over it with a tolerance window —
 * which matters, because with `E2E_KEEP=1` a re-run can start seconds after the
 * last one and replay the very same DevEUI at FCnt 0.
 */
export async function eventStoreNow(pool: Pool): Promise<Date> {
  const { rows } = await pool.query<{ now: Date }>('select now() as now');
  return rows[0].now;
}

/**
 * Poll `event_up` for the row belonging to one specific uplink and return it.
 *
 * Correlation is `(dev_eui, f_cnt)` bounded below by `since`: the FCnt pins the
 * frame, and the time bound rules out an identically-numbered frame from an
 * earlier run whose rows are still in the volume. Rows are ordered oldest-first so
 * that when the demo loop happens to reuse our FCnt inside the same window we take
 * the earlier row — ours, since `since` is read immediately before the send.
 *
 * `f_port`, `dr` and `tx_info` are returned rather than filtered on, so a mismatch
 * shows up as a readable diff in the test instead of an opaque timeout.
 */
export async function waitForEventUp(
  pool: Pool,
  devEui: string,
  fCnt: number,
  since: Date,
  timeoutMs: number,
): Promise<StoredUplink> {
  const deadline = Date.now() + timeoutMs;
  let lastErr: Error | undefined;
  while (Date.now() < deadline) {
    try {
      const { rows } = await pool.query<EventUpRow>(
        `select f_cnt, f_port, dr, time, tx_info, object
           from event_up
          where lower(dev_eui) = lower($1)
            and f_cnt = $2
            and time >= $3
          order by time asc
          limit 1`,
        [devEui, fCnt, since],
      );
      if (rows.length > 0) {
        const row = rows[0];
        return {
          fCnt: Number(row.f_cnt),
          fPort: row.f_port,
          dr: row.dr,
          time: row.time,
          txInfo: row.tx_info,
          object: row.object,
        };
      }
    } catch (err) {
      lastErr = err as Error; // table may not exist yet on a brand-new stack
    }
    await sleep(500);
  }
  throw new Error(
    `no event_up row for devEui=${devEui} fCnt=${fCnt} with time >= ${since.toISOString()} ` +
      `within ${timeoutMs}ms` +
      (lastErr ? ` (last query error: ${lastErr.message})` : ''),
  );
}
