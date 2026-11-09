import {
  type AlertmanagerEndpoint,
  type AlertmanagerError,
  listAlerts,
} from "../clients/alertmanager.ts";
import type { Database } from "../db/client.ts";
import { listIgnoredAlertNames } from "../db/ignored-alert-names.ts";
import {
  listFiringOccurrences,
  listNoisiestAlerts,
  listOccurrenceFirings,
  listOccurrencesChangedSince,
  listReceivers,
} from "../db/queries.ts";
import type { Occurrence } from "../domain/occurrence.ts";
import {
  type AlertCounts,
  type AlertmanagerAlert,
  alertListOf,
  countAlerts,
  type Delivery,
  deliveryOf,
  type IgnoredAlertNames,
  type ListedAlert,
  longestFiring,
} from "../domain/overview.ts";
import type { SilencedOccurrence } from "../domain/silence.ts";
import { alertmanagerSource } from "../sources/alertmanager/index.ts";
import { alertmanagerReads, cachedRead, type Reading } from "./alertmanager-reads.ts";
import type { IrmHeartbeatReading, IrmHeartbeats } from "./irm-heartbeats.ts";
import type { InstanceSilence, Silences } from "./silences.ts";

/** Each instance's alerts, read from its Alertmanager at most once per window (ADR 0010). */
export interface AlertmanagerAlerts {
  /** One reading per configured instance, by instance name. */
  readAll(): Promise<{ instance: string; reading: Reading<readonly AlertmanagerAlert[]> }[]>;
  /** The instance's reading, from the same cache; null when it has no Alertmanager. */
  read(instance: string): Promise<Reading<readonly AlertmanagerAlert[]> | null>;
}

export interface AlertmanagerAlertsOptions {
  readonly now?: () => Date;
  /** An Alertmanager could not be read; the home view shows its last alerts meanwhile. */
  readonly onReadError?: (instance: string, error: AlertmanagerError) => void;
}

export function alertmanagerAlertsFrom(
  endpoints: ReadonlyMap<string, AlertmanagerEndpoint>,
  { now = () => new Date(), onReadError = () => {} }: AlertmanagerAlertsOptions = {},
): AlertmanagerAlerts {
  // By instance name, the order readAll answers in.
  const caches = new Map(
    [...endpoints]
      .toSorted(([a], [b]) => a.localeCompare(b))
      .map(([instance, endpoint]) => [
        instance,
        cachedRead(
          () => listAlerts(endpoint),
          now,
          (error) => onReadError(instance, error),
          alertmanagerReads,
        ),
      ]),
  );
  return {
    readAll: () =>
      Promise.all(
        [...caches].map(async ([instance, cache]) => ({ instance, reading: await cache.read() })),
      ),
    read: async (instance) => (await caches.get(instance)?.read()) ?? null,
  };
}

/** One instance's Alertmanager, as the home view shows it. */
export interface AlertmanagerOverview {
  readonly instance: string;
  /** Why the latest read failed; null when it succeeded. */
  readonly error: string | null;
  /** From the last read that succeeded; null until one has. */
  readonly last: {
    readonly readAt: Date;
    readonly counts: AlertCounts;
    readonly delivery: Delivery<SilencedOccurrence>;
  } | null;
  /** Whether Grafana IRM receives its heartbeat; null without an IRM integration (ADR 0012). */
  readonly irm: IrmHeartbeatReading | null;
}

/** One instance's Alertmanager's alerts, as the tile counts them, for its list. */
export interface AlertmanagerAlertList {
  readonly instance: string;
  /** Why the latest read failed; null when it succeeded. */
  readonly error: string | null;
  /** From the last read that succeeded; null until one has. */
  readonly last: { readonly readAt: Date; readonly alerts: readonly ListedAlert[] } | null;
}

interface NoisyAlert {
  /** The alert's newest occurrence. */
  readonly occurrence: SilencedOccurrence;
  /** Its fired, reopened and resent events in the window. */
  readonly events: number;
}

export interface Home {
  /** Every configured instance, by name. */
  readonly alertmanagers: readonly AlertmanagerOverview[];
  /** Active now, on every instance, the soonest to end first. */
  readonly silences: readonly InstanceSilence[];
  readonly noisiest: readonly NoisyAlert[];
  /** The firing occurrences that started first. */
  readonly longestFiring: readonly SilencedOccurrence[];
}

const shown = 10;
const noisyWindowMs = 24 * 60 * 60 * 1000;
// One event is just an alert firing; noise starts with the second.
const noisyFromEvents = 2;

export async function getHome(
  db: Database,
  silences: Silences,
  alerts: AlertmanagerAlerts,
  heartbeats: IrmHeartbeats,
  now: Date,
): Promise<Home> {
  const reads = alerts.readAll();
  const [readings, irm, ignored, changed, activeSilences, firing, receivers, noisiest] =
    await Promise.all([
      reads,
      heartbeats.readAll(),
      ignoredAlertNames(db),
      reads.then((readings) =>
        listOccurrencesChangedSince(
          db,
          alertmanagerSource.id,
          readings.flatMap(({ instance, reading }) =>
            reading.last === null ? [] : [{ instance, at: reading.last.readAt }],
          ),
        ),
      ),
      silences.listActive(),
      listFiringOccurrences(db).then((occurrences) => silences.annotate(occurrences)),
      listReceivers(db),
      listNoisiestAlerts(db, {
        since: new Date(now.getTime() - noisyWindowMs),
        minEvents: noisyFromEvents,
        limit: shown,
      }).then((noisy) => withSilences(silences, noisy)),
    ]);
  return {
    alertmanagers: readings.map(({ instance, reading }) =>
      overviewOf(instance, reading, irm.get(instance) ?? null, ignored, {
        receivers: new Set(
          receivers.filter((row) => row.instance === instance).map((row) => row.receiver),
        ),
        firing: firing.filter(fromAlertmanager(instance)),
        changed: changed.filter(fromAlertmanager(instance)),
      }),
    ),
    silences: activeSilences,
    noisiest,
    longestFiring: longestFiring(firing, shown),
  };
}

/**
 * Read for each request, never cached with the alerts, so a change applies to the next
 * request even within the same Alertmanager read (ADR 0011).
 */
async function ignoredAlertNames(db: Database): Promise<IgnoredAlertNames> {
  return new Set(await listIgnoredAlertNames(db));
}

/** Occurrences of the instance's Alertmanager in Achtung. */
const fromAlertmanager =
  (instance: string) => (occurrence: { readonly instance: string; readonly source: string }) =>
    occurrence.instance === instance && occurrence.source === alertmanagerSource.id;

type ChangedOccurrence = Awaited<ReturnType<typeof listOccurrencesChangedSince>>[number];

function overviewOf(
  instance: string,
  reading: Reading<readonly AlertmanagerAlert[]>,
  irm: IrmHeartbeatReading | null,
  ignored: IgnoredAlertNames,
  achtung: {
    readonly receivers: ReadonlySet<string>;
    readonly firing: readonly SilencedOccurrence[];
    readonly changed: readonly ChangedOccurrence[];
  },
): AlertmanagerOverview {
  const { last } = reading;
  return {
    instance,
    error: reading.error?.reason ?? null,
    last:
      last === null
        ? null
        : {
            readAt: last.readAt,
            counts: countAlerts(last.value, ignored),
            delivery: deliveryOf(last.value, ignored, {
              receivers: achtung.receivers,
              firing: achtung.firing,
              changedAfterRead: achtung.changed,
              readAt: last.readAt,
            }),
          },
    irm,
  };
}

async function withSilences(
  silences: Silences,
  noisy: readonly { readonly occurrence: Occurrence; readonly events: number }[],
): Promise<NoisyAlert[]> {
  const occurrences = await silences.annotate(noisy.map((alert) => alert.occurrence));
  return occurrences.map((occurrence, index) => ({
    occurrence,
    events: noisy[index]?.events ?? 0,
  }));
}

/**
 * The alerts behind the instance's tile, from the same read as its counts; null when the
 * instance has no Alertmanager.
 */
export async function listAlertmanagerAlerts(
  db: Database,
  silences: Silences,
  alerts: AlertmanagerAlerts,
  instance: string,
): Promise<AlertmanagerAlertList | null> {
  const reading = await alerts.read(instance);
  if (reading === null) {
    return null;
  }
  const error = reading.error?.reason ?? null;
  const { last } = reading;
  if (last === null) {
    return { instance, error, last: null };
  }
  const [occurrences, active, ignored] = await Promise.all([
    listOccurrenceFirings(db, alertmanagerSource.id, instance, last.value),
    silences.activeOn(instance),
    ignoredAlertNames(db),
  ]);
  return {
    instance,
    error,
    last: {
      readAt: last.readAt,
      alerts: alertListOf(last.value, ignored, {
        occurrences,
        silences: active,
      }),
    },
  };
}
