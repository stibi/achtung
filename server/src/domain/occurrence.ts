import type { AlertState, IncomingAlert } from "./alert.ts";
import type { ChannelSlug, InstanceName } from "./channel.ts";

type OccurrenceStatus = AlertState["status"];

/**
 * Something that happened to an occurrence. Events make up an alert's history. `resent`
 * is a repeat notification for an alert still firing, counted at most once per
 * `resendQuietPeriodMs` so it resurfaces like a reminder (ADR 0009).
 */
export type EventKind = "fired" | "resolved" | "reopened" | "resent";

/** A repeat within this long of the occurrence's last event is not news. */
export const resendQuietPeriodMs = 60 * 60 * 1000;

/**
 * What a notification with `incoming` status, received at `now`, means for an occurrence
 * that is currently `current` (null: not seen before). Null means nothing happened: the
 * notification updates the occurrence but is not news.
 */
export function eventFor(
  current: { readonly status: OccurrenceStatus; readonly lastEventAt: Date } | null,
  incoming: OccurrenceStatus,
  now: Date,
): EventKind | null {
  if (current?.status === incoming) {
    const quiet = now.getTime() - current.lastEventAt.getTime() < resendQuietPeriodMs;
    // Alertmanager sends a resolved alert once; only a firing one is resent as a reminder.
    return incoming === "firing" && !quiet ? "resent" : null;
  }
  if (incoming === "resolved") {
    return "resolved";
  }
  // Same startsAt firing again after a resolve: Alertmanager's resolve_timeout ended it
  // too early, so this is the same occurrence coming back, not a new one.
  return current === null ? "fired" : "reopened";
}

/** An occurrence as Achtung stores it: what the source reported plus what Achtung tracks. */
export type Occurrence = IncomingAlert & {
  readonly id: number;
  readonly instance: InstanceName;
  readonly channel: ChannelSlug;
  readonly source: string;
  readonly firstReceivedAt: Date;
  readonly lastReceivedAt: Date;
  /** When the last event happened. A repeat moves it only when it counts as `resent`. */
  readonly lastEventAt: Date;
  readonly lastEventKind: EventKind;
  readonly notificationCount: number;
};

export interface OccurrenceEvent {
  readonly id: number;
  readonly kind: EventKind;
  readonly recordedAt: Date;
}
