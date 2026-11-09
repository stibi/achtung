import { parseSeverity, type Severity } from "./alert.ts";

// The home view's picture of each Alertmanager (ADR 0010): what it has open, read from
// the Alertmanager itself, and whether Achtung got what it should have.

/** An alert as an Alertmanager's API reports it (GET /api/v2/alerts). */
export interface AlertmanagerAlert {
  readonly fingerprint: string;
  readonly labels: Readonly<Record<string, string>>;
  readonly startsAt: Date;
  /** `suppressed`: silenced, inhibited or muted; `unprocessed`: not routed yet. */
  readonly state: "active" | "suppressed" | "unprocessed";
  /** Ids of the silences muting it. */
  readonly silencedBy: readonly string[];
  /** Fingerprints of the alerts inhibiting it. */
  readonly inhibitedBy: readonly string[];
  /** Names of the receivers its routes send it to. */
  readonly receivers: readonly string[];
}

/** Alerts that are notifying, by severity. */
interface OpenCounts {
  readonly total: number;
  readonly critical: number;
  readonly warning: number;
  readonly info: number;
  /** No severity label, or one Achtung doesn't know. */
  readonly other: number;
}

export interface AlertCounts {
  readonly open: OpenCounts;
  readonly silenced: number;
  /** Inhibited and not silenced: a silenced alert counts as silenced only. */
  readonly inhibited: number;
  /** Whether the always-firing Watchdog alert is there, i.e. the alerting pipeline works. */
  readonly watchdog: "firing" | "absent";
}

/** An alert Alertmanager has open that should have reached Achtung but didn't. */
interface MissingAlert {
  readonly fingerprint: string;
  readonly title: string;
  readonly severity: Severity;
  readonly startsAt: Date;
}

/** One firing of an alert: Alertmanager's fingerprint, or an occurrence's sourceKey, and start. */
interface Firing {
  readonly sourceKey: string;
  readonly startsAt: Date;
}

/** What Achtung stores of a firing occurrence that the delivery check needs. */
interface FiringOccurrence extends Firing {
  readonly lastReceivedAt: Date;
}

export interface Delivery<T extends FiringOccurrence> {
  /** Oldest first. */
  readonly missingInAchtung: readonly MissingAlert[];
  /** Firing in Achtung, gone from Alertmanager: a resolve that never arrived. Oldest first. */
  readonly staleInAchtung: readonly T[];
}

/**
 * How long a notification may take: Alertmanager waits `group_wait` before a group's first
 * notification and `group_interval` before the next, so a younger difference is no fault.
 */
export const deliveryGraceMs = 10 * 60 * 1000;

const watchdog = "Watchdog";
// They fire all the time by design, so they would only ever inflate the counts.
const alwaysFiring: ReadonlySet<string | undefined> = new Set([watchdog, "InfoInhibitor"]);

const nameOf = (alert: AlertmanagerAlert) => alert.labels["alertname"];

// Fingerprint and start, like an occurrence (ADR 0007): a re-fire is a new one.
const keyOf = ({ sourceKey, startsAt }: Firing) => `${sourceKey}@${startsAt.getTime()}`;
const alertKey = (alert: AlertmanagerAlert) =>
  keyOf({ sourceKey: alert.fingerprint, startsAt: alert.startsAt });

const isAlwaysFiring = (alert: AlertmanagerAlert) => alwaysFiring.has(nameOf(alert));

const isNotifying = (alert: AlertmanagerAlert) => alert.state !== "suppressed";

export function countAlerts(alerts: readonly AlertmanagerAlert[]): AlertCounts {
  const counted = alerts.filter((alert) => !isAlwaysFiring(alert));
  const suppressed = counted.filter((alert) => !isNotifying(alert));
  const silenced = suppressed.filter((alert) => alert.silencedBy.length > 0);
  const severities = counted
    .filter(isNotifying)
    .map((alert) => parseSeverity(alert.labels["severity"]));
  const withSeverity = (severity: Severity) => severities.filter((s) => s === severity).length;
  return {
    open: {
      total: severities.length,
      critical: withSeverity("critical"),
      warning: withSeverity("warning"),
      info: withSeverity("info"),
      other: withSeverity("unknown"),
    },
    silenced: silenced.length,
    inhibited: suppressed.filter(
      (alert) => alert.silencedBy.length === 0 && alert.inhibitedBy.length > 0,
    ).length,
    watchdog: alerts.some((alert) => nameOf(alert) === watchdog) ? "firing" : "absent",
  };
}

/**
 * Compares what an Alertmanager had open at `readAt` with what fires in Achtung for that
 * instance, firing by firing (fingerprint and start). Only alerts routed to a receiver
 * Achtung has heard from can be missing: Achtung sees nothing else. Nothing is changed;
 * this only reports (ADR 0010).
 */
export function deliveryOf<T extends FiringOccurrence>(
  alerts: readonly AlertmanagerAlert[],
  {
    receivers,
    firing,
    changedAfterRead,
    readAt,
  }: {
    /** Receivers that have delivered to Achtung from this instance. */
    readonly receivers: ReadonlySet<string>;
    /** The instance's firing occurrences from this Alertmanager. */
    readonly firing: readonly T[];
    /**
     * The instance's occurrences with an event after the read, in any status: newer than
     * the read, so never missing (e.g. one that resolved since).
     */
    readonly changedAfterRead: readonly Firing[];
    readonly readAt: Date;
  },
): Delivery<T> {
  const settled = (at: Date) => readAt.getTime() - at.getTime() > deliveryGraceMs;
  const inAchtung = new Set([...firing, ...changedAfterRead].map(keyOf));
  const inAlertmanager = new Set(alerts.map(alertKey));
  return {
    missingInAchtung: alerts
      .filter(isNotifying)
      .filter((alert) => alert.receivers.some((receiver) => receivers.has(receiver)))
      .filter((alert) => settled(alert.startsAt) && !inAchtung.has(alertKey(alert)))
      .toSorted(oldestFirst)
      .map((alert) => ({
        fingerprint: alert.fingerprint,
        title: nameOf(alert) ?? alert.fingerprint,
        severity: parseSeverity(alert.labels["severity"]),
        startsAt: alert.startsAt,
      })),
    staleInAchtung: firing
      .filter((occurrence) => !inAlertmanager.has(keyOf(occurrence)))
      .filter((occurrence) => settled(occurrence.lastReceivedAt))
      .toSorted(oldestFirst),
  };
}

/** The `limit` firing occurrences that started first. */
export function longestFiring<T extends { readonly startsAt: Date; readonly id: number }>(
  firing: readonly T[],
  limit: number,
): T[] {
  return firing.toSorted((a, b) => oldestFirst(a, b) || a.id - b.id).slice(0, limit);
}

function oldestFirst(a: { readonly startsAt: Date }, b: { readonly startsAt: Date }): number {
  return a.startsAt.getTime() - b.startsAt.getTime();
}
