// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Intelligent Farming Foundation

/**
 * The mock ag sensors this harness simulates.
 *
 * Each entry maps to a real normalized codec in
 * `@intelligent-farming/lorawan-codec-normalization`. We pull the console-ready
 * `codec.js` (to attach to the ChirpStack device profile) and the decode-verified
 * test vectors (raw bytes in, expected decoded object out) straight from that
 * package, so the mocked payloads are guaranteed to decode and the e2e assertions
 * compare against the codec's own authored expectations.
 *
 * Credentials are derived deterministically from the 1-based index so provisioning
 * and tests are reproducible across runs.
 */

import { codecScript } from '@intelligent-farming/lorawan-codec-normalization';
// `vectors` is a public registry function but isn't re-exported from the package
// root (still true in 0.2.0); the dist/ module (and the codecs/ it reads) both
// ship in the npm tarball, so importing it from the subpath is safe.
import { vectors as codecVectors } from '@intelligent-farming/lorawan-codec-normalization/dist/registry';

export interface MockSensor {
  /** Stable id used in logs and as the ChirpStack device/profile name. */
  id: string;
  vendor: string;
  device: string;
  category: string;
  index: number;
  /**
   * Set when this device's profile should carry a codec that *fails* rather
   * than the real one for its vendor/device.
   *
   * The bytes on the wire stay real -- the vendor and device above still name
   * a curated codec, so `dataVectors` still replays its own decode-verified
   * test vectors -- and only the script installed in ChirpStack is swapped.
   * That is the point: a device whose payload is perfectly good and whose
   * decoder throws is what a fleet actually meets, and it is the only way to
   * see what ChirpStack does with one. It still publishes the uplink, with no
   * `object`, so the raw capture lands downstream with zero readings. The
   * telemetry bridge's "ingestion is never gated on decode" is that fact, and
   * before this device nothing on the bench exercised it.
   */
  brokenCodec?: true;
  /** ABP session credentials (hex strings, no separators). */
  devEui: string;
  devAddr: string;
  nwkSKey: string;
  appSKey: string;
}

/** One decode-verified uplink test vector for a sensor. */
export interface UplinkVector {
  description: string;
  fPort: number;
  bytes: number[];
  /** The decoded object the codec produces (== ChirpStack's `object`). */
  expected: Record<string, unknown>;
}

const twoHex = (n: number): string => (n & 0xff).toString(16).padStart(2, '0');

/** Deterministic per-device ABP credentials from the sensor index. */
function creds(index: number): Pick<
  MockSensor,
  'devEui' | 'devAddr' | 'nwkSKey' | 'appSKey'
> {
  return {
    // 16 hex chars; a recognizable "mock" prefix.
    devEui: 'f0000000000000' + twoHex(index),
    // 8 hex chars; top byte 0x01 keeps NwkID 0 (matches net_id 000000).
    devAddr: '010000' + twoHex(index),
    // 32 hex chars each; distinct per device.
    nwkSKey: twoHex(index).repeat(16),
    appSKey: twoHex(0x80 + index).repeat(16),
  };
}

const CATALOG: Omit<MockSensor, 'devEui' | 'devAddr' | 'nwkSKey' | 'appSKey'>[] = [
  // ---- Wire-format / shape coverage -------------------------------------------
  { id: 'dragino-lse01', vendor: 'dragino', device: 'lse01', category: 'soil-monitor', index: 1 },
  { id: 'milesight-em500-smtc', vendor: 'milesight-iot', device: 'em500-smtc', category: 'soil-monitor', index: 2 },
  { id: 'decentlab-dl-trs12', vendor: 'decentlab', device: 'dl-trs12', category: 'soil-monitor', index: 3 },
  { id: 'dragino-llms01', vendor: 'dragino', device: 'llms01', category: 'leaf-wetness', index: 4 },
  { id: 'decentlab-dl-atm41', vendor: 'decentlab', device: 'dl-atm41', category: 'weather-station', index: 5 },
  // Multilayer probe: its vectors decode to the reserved `channels[]` array (one
  // entry per depth), which exercises a nested array through ChirpStack's
  // protobuf Struct conversion and the PostgreSQL integration.
  { id: 'decentlab-dl-smtp', vendor: 'decentlab', device: 'dl-smtp', category: 'soil-monitor', index: 6 },

  // ---- First-deployment fleet --------------------------------------------------
  // Everything below is a device actually going into the ground first, so the
  // bench covers the real hardware rather than a representative sample of it:
  // the SenseCAP S2120 weather sensor and the full Makerfabs AgroSense line
  // (every device under codecs/makerfabs/ is AgroSense-branded — TTN describes
  // each as "The AgroSense …" with a productURL on agrosense.cc).
  //
  // These are deliberately whole-family, not one-per-category: two devices whose
  // codecs are supposed to agree only demonstrably agree if both are replayed
  // through ChirpStack. makerfabs/gps-tracker-neo-6m and -pa1010d read one shared
  // wire format, and makerfabs/{ath20,air-temperature-and-humidity,
  // temperature-humidity-sht31} read another, so the pairs sit side by side here.
  { id: 'sensecap-s2120-8-in-1', vendor: 'sensecap', device: 'sensecaps2120-8-in-1', category: 'weather-station', index: 7 },

  { id: 'makerfabs-soil-monitor', vendor: 'makerfabs', device: 'soil-monitor', category: 'soil-monitor', index: 8 },
  { id: 'makerfabs-soil-moisture', vendor: 'makerfabs', device: 'soil-moisture', category: 'soil-monitor', index: 9 },
  { id: 'makerfabs-leaf-moisture-sn-3001', vendor: 'makerfabs', device: 'leaf-moisture-sn-3001', category: 'leaf-wetness', index: 10 },
  { id: 'makerfabs-barometric-pressure', vendor: 'makerfabs', device: 'barometric-pressure', category: 'weather-station', index: 11 },
  { id: 'makerfabs-co2', vendor: 'makerfabs', device: 'co2', category: 'air-quality', index: 12 },
  { id: 'makerfabs-light-intensity', vendor: 'makerfabs', device: 'light-intensity', category: 'light', index: 13 },
  { id: 'makerfabs-ath20', vendor: 'makerfabs', device: 'ath20', category: 'climate', index: 14 },
  { id: 'makerfabs-air-temperature-and-humidity', vendor: 'makerfabs', device: 'air-temperature-and-humidity', category: 'climate', index: 15 },
  { id: 'makerfabs-temperature-humidity-sht31', vendor: 'makerfabs', device: 'temperature-humidity-sht31', category: 'climate', index: 16 },
  { id: 'makerfabs-rtd-pt1000-temperature', vendor: 'makerfabs', device: 'rtd-pt1000-temperature', category: 'temperature', index: 17 },
  { id: 'makerfabs-pipe-pressure', vendor: 'makerfabs', device: 'pipe-pressure', category: 'process-pressure', index: 18 },
  // Second `channels[]` emitter in the fleet, and the only non-soil one: four
  // single-ended ADC inputs as one entry each. decentlab/dl-smtp covers a probe
  // whose entries carry a `soil` group; this covers entries carrying `analog`,
  // so the flattener is not being proven against a single nesting shape.
  { id: 'makerfabs-4-channel-adc', vendor: 'makerfabs', device: '4-channel-adc', category: 'analog-interface', index: 19 },
  { id: 'makerfabs-positioning-water-leak', vendor: 'makerfabs', device: 'positioning-water-leak', category: 'water-leak', index: 20 },
  { id: 'makerfabs-none-position-rope-water-leak', vendor: 'makerfabs', device: 'none-position-rope-water-leak', category: 'water-leak', index: 21 },
  { id: 'makerfabs-gps-tracker-neo-6m', vendor: 'makerfabs', device: 'gps-tracker-neo-6m', category: 'gps-tracker', index: 22 },
  { id: 'makerfabs-gps-tracker-pa1010d', vendor: 'makerfabs', device: 'gps-tracker-pa1010d', category: 'gps-tracker', index: 23 },

  // ---- Decode failure ----------------------------------------------------------
  // A real device sending real bytes behind a codec that throws. It reuses
  // dragino/lse01's vectors deliberately: the uplink has to be one that *would*
  // decode, or this proves a bad payload rather than a bad decoder.
  //
  // Its category is what it would have been; nothing downstream can learn it,
  // because category comes from the decoded make/model and there is no decode.
  // That is the shape an operator has to curate by hand, so having one on the
  // bench is worth more than the tidy row it costs.
  { id: 'broken-codec', vendor: 'dragino', device: 'lse01', category: 'soil-monitor', index: 24, brokenCodec: true },
];

export const SENSORS: MockSensor[] = CATALOG.map((c) => ({ ...c, ...creds(c.index) }));

/**
 * A decoder that throws on every uplink, for {@link MockSensor.brokenCodec}.
 *
 * It throws rather than returning `{}` or an `errors` array, because those are
 * codec conventions ChirpStack handles gracefully and this is meant to be the
 * ugly case: an exception out of the JS runtime, which is what a real codec
 * with a bug does.
 */
const THROWING_CODEC = [
  '// A deliberately broken codec: the bench needs one device whose decode fails.',
  'function decodeUplink(input) {',
  '  throw new Error("mock-sensors: this codec fails on purpose");',
  '}',
  'function encodeDownlink(input) {',
  '  throw new Error("mock-sensors: this codec fails on purpose");',
  '}',
].join('\n');

/** The `codec.js` text to install in this sensor's ChirpStack device profile. */
export function sensorCodec(sensor: MockSensor): string {
  return sensor.brokenCodec === true ? THROWING_CODEC : codecScript(sensor.vendor, sensor.device);
}

// The codec package's own `vectors()` reads and JSON-parses vectors.json on every
// call — only its `device()` lookup is cached. Both the demo loop and the e2e
// suite ask for the same vectors repeatedly, so memoize here, at the one place
// that resolves them, rather than making every caller hoist its own copy.
const vectorCache = new Map<string, UplinkVector[]>();

/**
 * The sensor's data-carrying uplink vectors (error vectors are filtered out).
 * These are the raw payloads the harness replays and the expected decoded
 * objects the e2e suite asserts against. Memoized per sensor id.
 */
export function dataVectors(sensor: MockSensor): UplinkVector[] {
  const cached = vectorCache.get(sensor.id);
  if (cached) return cached;
  const { uplink } = codecVectors(sensor.vendor, sensor.device);
  const out: UplinkVector[] = [];
  for (const raw of uplink as Array<{
    description?: string;
    input?: { fPort?: number; bytes?: number[] };
    expected?: { data?: Record<string, unknown> };
  }>) {
    if (raw?.expected?.data && raw.input?.bytes && typeof raw.input.fPort === 'number') {
      out.push({
        description: raw.description ?? '',
        fPort: raw.input.fPort,
        bytes: raw.input.bytes,
        expected: raw.expected.data,
      });
    }
  }
  if (out.length === 0) {
    throw new Error(`no data vectors for ${sensor.vendor}/${sensor.device}`);
  }
  vectorCache.set(sensor.id, out);
  return out;
}
