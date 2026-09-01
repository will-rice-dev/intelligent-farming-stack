// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Intelligent Farming Foundation

/**
 * End-to-end test: a mocked sensor uplink, injected via the Semtech UDP gateway
 * bridge, must be decoded by ChirpStack and land BOTH on the MQTT application
 * stream AND in the Postgres event store — with the decoded `object` matching the
 * codec's own authored expectation, and with the transport metadata ChirpStack
 * reports matching what the emitter actually transmitted.
 *
 * Every data vector of every sensor is sent, over 24 devices, not
 * just the first. Three reasons:
 *   - the data rate is derived from the payload length, so it varies per *vector*
 *     as well as per sensor (decentlab/dl-trs12 is DR1 for its two 13-byte vectors
 *     and DR3 for its 7-byte one; milesight-iot/em500-smtc is DR3 at 14 bytes and
 *     DR2 at 10). Sending only vector 0 would leave that variation — and so the
 *     transport-metadata assertions below — largely untested;
 *   - the vectors are chosen for coverage. decentlab/dl-smtp's three are a full
 *     8-depth profile, a partial probe with disconnected depths, and a
 *     battery-only uplink carrying no `channels` key at all — the last being the
 *     only coverage for the reserved `channels[]` array being *absent* through
 *     ChirpStack's protobuf-Struct conversion and the PostgreSQL integration; and
 *   - several vectors exist specifically to pin a decode that used to be wrong,
 *     and they only pin it end-to-end if they are actually sent:
 *     makerfabs/barometric-pressure's sub-zero temperature, and
 *     makerfabs/gps-tracker-neo-6m's southern/western fix. Vector 0 of each is
 *     the benign case.
 *
 * Requires a running stack (see scripts/e2e.sh). Connection details come from the
 * environment / /shared/config.json via loadConfig().
 */

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { Pool } from 'pg';

import { loadConfig, type Config } from '../src/config';
import { Emitter, type EmitResult } from '../src/emit';
import { provisionAll } from '../src/provision';
import { SENSORS, dataVectors } from '../src/sensors';
import {
  MqttCollector,
  byFCnt,
  eventDr,
  eventFCnt,
  eventStoreNow,
  waitForEventUp,
} from './helpers';

const cfg: Config = loadConfig();

let collector: MqttCollector;
let pool: Pool;
let emitter: Emitter;

beforeAll(async () => {
  await provisionAll(cfg);
  collector = new MqttCollector();
  await collector.connect(cfg.mqttUrl);
  pool = new Pool({ connectionString: cfg.pgUrl });
  emitter = new Emitter(cfg);
});

afterAll(async () => {
  emitter?.close();
  await collector?.end();
  await pool?.end();
});

describe('mocked sensor uplinks flow through ChirpStack end-to-end', () => {
  for (const sensor of SENSORS) {
    // Resolve this sensor's vectors once, here at collection time: dataVectors()
    // re-reads and re-parses the codec package's vector file on every call, and
    // the list is fixed for the run.
    const vectors = dataVectors(sensor);

    describe(sensor.id, () => {
      vectors.forEach((vector, index) => {
        it(`vector ${index} (${vector.bytes.length} B): ${vector.description}`, async () => {
          // The event store's clock, read *before* the send: the row for this
          // uplink must be stamped at or after it. See eventStoreNow() for why the
          // bound comes from Postgres and not from this process.
          const since = await eventStoreNow(pool);

          // Annotated so the emitter's reported-transmission contract is checked
          // here at compile time: every expectation below is derived from `sent`,
          // never hardcoded.
          const sent: EmitResult = await emitter.emit(sensor, vector);

          // The MQTT waiter is registered after the send because the FCnt we
          // correlate on is only known from emit's result. That does not
          // reintroduce the "missed event" risk the old pre-send registration
          // guarded against: the collector has buffered every uplink since
          // beforeAll, and waitFor() scans that buffer by predicate before it
          // starts waiting, so an event that beat us to the broker is still found.
          //
          // Correlating on FCnt is what makes the wait trustworthy at all — the
          // compose `mock-sensors` demo service publishes for these same 24
          // DevEUIs every MOCK_INTERVAL_SECONDS, cycling every vector, so "the
          // next event for this DevEUI" is very often not ours.
          const evt = await collector.waitFor(
            sensor.devEui,
            byFCnt(sent.fCnt),
            15_000,
            `FCnt ${sent.fCnt}`,
          );

          expect(evt.deviceInfo?.devEui?.toLowerCase()).toBe(sensor.devEui);
          expect(eventFCnt(evt)).toBe(sent.fCnt);
          expect(evt.fPort).toBe(vector.fPort);
          if (sensor.brokenCodec === true) {
            // The whole reason this device is in the fleet: ChirpStack still
            // publishes and still archives the uplink when the codec throws,
            // it just has nothing decoded to attach. Asserted here rather than
            // assumed, because everything downstream that claims "ingestion is
            // never gated on decode" rests on it -- if ChirpStack instead
            // swallowed the event, the farm store's zero-readings capture would
            // be proving something else entirely.
            expect(evt.object).toBeUndefined();
          } else {
            expect(evt.object).toEqual(vector.expected);
          }

          // Transport metadata. Both values are derived per (sensor, vector) — the
          // DR from the payload length, the channel from the sensor index — so they
          // are only ever compared against emit's own report, never a hardcoded
          // expectation. This is the guard against silently regressing to "every
          // frame at DR0": a 39–41 byte payload cannot be modulated at SF10BW125
          // (11-byte limit, and ~600 ms time-on-air, past the FCC dwell limit), yet
          // ChirpStack polices none of that and stores such a frame happily with
          // dr = 0, poisoning every downstream airtime/link-budget calculation.
          expect(eventDr(evt)).toBe(sent.dr);
          expect(evt.txInfo?.frequency).toBe(sent.frequencyHz); // ChirpStack reports Hz

          // Same frame, read back out of the store — correlated on (DevEUI, FCnt)
          // and bounded by `since`, so a surviving row from an earlier run (the
          // event volume is not wiped between runs) can never stand in for it.
          const stored = await waitForEventUp(pool, sensor.devEui, sent.fCnt, since, 15_000);
          expect(stored.fCnt).toBe(sent.fCnt);
          expect(stored.fPort).toBe(vector.fPort);
          expect(stored.dr).toBe(sent.dr);
          expect(stored.txInfo?.frequency).toBe(sent.frequencyHz);
          if (sensor.brokenCodec === true) {
            // Same claim on the archive side. `object` is null rather than
            // absent here: the PostgreSQL integration writes the column either
            // way, which is exactly the "the row lands, the decode did not"
            // shape the farm store mirrors.
            expect(stored.object ?? null).toBeNull();
          } else {
            expect(stored.object).toEqual(vector.expected);
          }
        });
      });
    });
  }
});
