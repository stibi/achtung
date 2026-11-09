import { parseSeverity, type Severity, summaryOf } from "./alert.ts";

// The home view's picture of each Alertmanager (ADR 0010): what it has open, read from
// the Alertmanager itself, and whether Achtung got what it should have.

/** An alert as an Alertmanager's API reports it (GET /api/v2/alerts). */
export interface AlertmanagerAlert {
  readonly fingerprint: string;
  readonly labels: Readonly<Record<string, string>>;
  readonly annotations: Readonly<Record<string, string>>;
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

/**
 * Alert names the Home views leave out, matched exactly against `alertname` (ADR 0011): a
 * shared setting, e.g. alerts that fire all the time by design, like Watchdog.
 */
export type IgnoredAlertNames = ReadonlySet<string | undefined>;

export interface AlertCounts {
  readonly open: OpenCounts;
  readonly silenced: number;
  /** Inhibited and not silenced: a silenced alert counts as silenced only. */
  readonly inhibited: number;
  /**
   * Whether the always-firing Watchdog alert is there, i.e. the alerting pipeline works.
   * Independent of the ignored names: ignoring Watchdog only keeps it out of the counts.
   */
  readonly watchdog: "firing" | "absent";
}

/**
 * Where an alert stands, as the counts see it: `active` notifies (an unprocessed alert
 * will), `silenced` has a silence, `inhibited` is only inhibited.
 */
type Standing = "active" | "silenced" | "inhibited";

/** An alert of an Alertmanager's list, with the Achtung occurrence of its firing, if any. */
export type ListedAlert = {
  readonly fingerprint: string;
  readonly title: string;
  readonly severity: Severity;
  readonly summary: string | null;
  readonly startsAt: Date;
  readonly labels: Readonly<Record<string, string>>;
  readonly annotations: Readonly<Record<string, string>>;
  /** The occurrence with the alert's fingerprint and start; null when Achtung has none. */
  readonly occurrenceId: number | null;
} & (
  | { readonly state: "active" | "inhibited" }
  | {
      readonly state: "silenced";
      /** When the latest silence muting it ends; null when none of them is known yet. */
      readonly silencedUntil: Date | null;
    }
);

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
  readonly labels: Readonly<Record<string, string>>;
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

const nameOf = (alert: AlertmanagerAlert) => alert.labels["alertname"];
const titleOf = (alert: AlertmanagerAlert) => nameOf(alert) ?? alert.fingerprint;
const severityOf = (alert: AlertmanagerAlert) => parseSeverity(alert.labels["severity"]);

// Fingerprint and start, like an occurrence (ADR 0007): a re-fire is a new one.
const keyOf = ({ sourceKey, startsAt }: Firing) => `${sourceKey}@${startsAt.getTime()}`;
const alertKey = (alert: AlertmanagerAlert) =>
  keyOf({ sourceKey: alert.fingerprint, startsAt: alert.startsAt });

// An alert without an alertname is never ignored: no name in the set is undefined.
const isIgnored = (labels: Readonly<Record<string, string>>, ignored: IgnoredAlertNames) =>
  ignored.has(labels["alertname"]);

const isNotifying = (alert: AlertmanagerAlert) => alert.state !== "suppressed";

// Goes by the state: an active alert naming a silence notifies. A suppressed alert with
// neither a silence nor an inhibition (muted by a time interval) stands nowhere.
function standingOf(alert: AlertmanagerAlert): Standing | null {
  if (isNotifying(alert)) {
    return "active";
  }
  if (alert.silencedBy.length > 0) {
    return "silenced";
  }
  return alert.inhibitedBy.length > 0 ? "inhibited" : null;
}

/** The alerts the counts and the list are about, each with its standing. */
function standings(alerts: readonly AlertmanagerAlert[], ignored: IgnoredAlertNames) {
  return alerts.flatMap((alert) => {
    const standing = isIgnored(alert.labels, ignored) ? null : standingOf(alert);
    return standing === null ? [] : [{ alert, standing }];
  });
}

/** Counts the alerts, leaving out the ignored ones; `watchdog` looks at every alert. */
export function countAlerts(
  alerts: readonly AlertmanagerAlert[],
  ignored: IgnoredAlertNames,
): AlertCounts {
  const counted = standings(alerts, ignored);
  const inStanding = (standing: Standing) =>
    counted.filter((entry) => entry.standing === standing).map(({ alert }) => alert);
  const severities = inStanding("active").map(severityOf);
  const withSeverity = (severity: Severity) => severities.filter((s) => s === severity).length;
  return {
    open: {
      total: severities.length,
      critical: withSeverity("critical"),
      warning: withSeverity("warning"),
      info: withSeverity("info"),
      other: withSeverity("unknown"),
    },
    silenced: inStanding("silenced").length,
    inhibited: inStanding("inhibited").length,
    watchdog: alerts.some((alert) => nameOf(alert) === watchdog) ? "firing" : "absent",
  };
}

const severityOrder: readonly Severity[] = ["critical", "warning", "info", "unknown"];

/**
 * The alerts `countAlerts` counts, each with its standing and its occurrence in Achtung,
 * matched firing by firing (fingerprint and start, ADR 0007). By severity, then the newest
 * start first, then by fingerprint.
 */
export function alertListOf(
  alerts: readonly AlertmanagerAlert[],
  ignored: IgnoredAlertNames,
  achtung: {
    /** The instance's occurrences from this Alertmanager, in any status. */
    readonly occurrences: readonly (Firing & { readonly id: number })[];
    /** The instance's silences known now, to tell when a silenced alert's silence ends. */
    readonly silences: readonly { readonly id: string; readonly endsAt: Date }[];
  },
): ListedAlert[] {
  // The lowest id wins when channels of the instance both have the firing.
  const occurrenceIds = new Map(
    achtung.occurrences
      .toSorted((a, b) => b.id - a.id)
      .map((occurrence) => [keyOf(occurrence), occurrence.id]),
  );
  return standings(alerts, ignored)
    .map(({ alert, standing }) => {
      const listed = {
        fingerprint: alert.fingerprint,
        title: titleOf(alert),
        severity: severityOf(alert),
        summary: summaryOf(alert.annotations),
        startsAt: alert.startsAt,
        labels: alert.labels,
        annotations: alert.annotations,
        occurrenceId: occurrenceIds.get(alertKey(alert)) ?? null,
      };
      return standing === "silenced"
        ? { ...listed, state: standing, silencedUntil: silenceEnd(alert, achtung.silences) }
        : { ...listed, state: standing };
    })
    .toSorted(
      (a, b) =>
        severityOrder.indexOf(a.severity) - severityOrder.indexOf(b.severity) ||
        b.startsAt.getTime() - a.startsAt.getTime() ||
        a.fingerprint.localeCompare(b.fingerprint),
    );
}

function silenceEnd(
  alert: AlertmanagerAlert,
  silences: readonly { readonly id: string; readonly endsAt: Date }[],
): Date | null {
  const ends = silences
    .filter((silence) => alert.silencedBy.includes(silence.id))
    .map((silence) => silence.endsAt.getTime());
  return ends.length === 0 ? null : new Date(Math.max(...ends));
}

/**
 * Compares what an Alertmanager had open at `readAt` with what fires in Achtung for that
 * instance, firing by firing (fingerprint and start). Only alerts routed to a receiver
 * Achtung has heard from can be missing: Achtung sees nothing else. Ignored alerts are
 * neither missing nor stale. Nothing is changed; this only reports (ADR 0010).
 */
export function deliveryOf<T extends FiringOccurrence>(
  alerts: readonly AlertmanagerAlert[],
  ignored: IgnoredAlertNames,
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
      .filter((alert) => !isIgnored(alert.labels, ignored))
      .filter((alert) => alert.receivers.some((receiver) => receivers.has(receiver)))
      .filter((alert) => settled(alert.startsAt) && !inAchtung.has(alertKey(alert)))
      .toSorted(oldestFirst)
      .map((alert) => ({
        fingerprint: alert.fingerprint,
        title: titleOf(alert),
        severity: severityOf(alert),
        startsAt: alert.startsAt,
      })),
    staleInAchtung: firing
      .filter((occurrence) => !isIgnored(occurrence.labels, ignored))
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
