import {
  type AlertmanagerEndpoint,
  type AlertmanagerError,
  listAlerts,
} from "../clients/alertmanager.ts";
import type { Database } from "../db/client.ts";
import {
  listFiringOccurrences,
  listNoisiestAlerts,
  listOccurrencesChangedSince,
  listReceivers,
} from "../db/queries.ts";
import type { Occurrence } from "../domain/occurrence.ts";
import {
  type AlertCounts,
  type AlertmanagerAlert,
  countAlerts,
  type Delivery,
  deliveryOf,
  longestFiring,
} from "../domain/overview.ts";
import type { SilencedOccurrence } from "../domain/silence.ts";
import { alertmanagerSource } from "../sources/alertmanager/index.ts";
import { cachedRead, type Reading } from "./alertmanager-reads.ts";
import type { InstanceSilence, Silences } from "./silences.ts";

/** Each instance's alerts, read from its Alertmanager at most once per window (ADR 0010). */
export interface AlertmanagerAlerts {
  /** One reading per configured instance, by instance name. */
  readAll(): Promise<{ instance: string; reading: Reading<readonly AlertmanagerAlert[]> }[]>;
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
  const caches = [...endpoints]
    .toSorted(([a], [b]) => a.localeCompare(b))
    .map(([instance, endpoint]) => ({
      instance,
      cache: cachedRead(
        () => listAlerts(endpoint),
        now,
        (error) => onReadError(instance, error),
      ),
    }));
  return {
    readAll: () =>
      Promise.all(
        caches.map(async ({ instance, cache }) => ({ instance, reading: await cache.read() })),
      ),
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
  now: Date,
): Promise<Home> {
  const reads = alerts.readAll();
  const [readings, changed, activeSilences, firing, receivers, noisiest] = await Promise.all([
    reads,
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
      overviewOf(instance, reading, {
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

/** Occurrences of the instance's Alertmanager in Achtung. */
const fromAlertmanager =
  (instance: string) => (occurrence: { readonly instance: string; readonly source: string }) =>
    occurrence.instance === instance && occurrence.source === alertmanagerSource.id;

type ChangedOccurrence = Awaited<ReturnType<typeof listOccurrencesChangedSince>>[number];

function overviewOf(
  instance: string,
  reading: Reading<readonly AlertmanagerAlert[]>,
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
            counts: countAlerts(last.value),
            delivery: deliveryOf(last.value, {
              receivers: achtung.receivers,
              firing: achtung.firing,
              changedAfterRead: achtung.changed,
              readAt: last.readAt,
            }),
          },
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
