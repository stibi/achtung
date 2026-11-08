import type { AlertState, IncomingAlert } from "./alert.ts";
import type { ChannelSlug, InstanceName } from "./channel.ts";

type OccurrenceStatus = AlertState["status"];

/** Something that happened to an occurrence. Events make up an alert's history. */
export type EventKind = "fired" | "resolved" | "reopened";

/**
 * What a notification with `incoming` status means for an occurrence that is currently
 * `current` (null: not seen before). Null means nothing happened: a repeat notification
 * updates the occurrence but is not news.
 */
export function eventFor(
  current: OccurrenceStatus | null,
  incoming: OccurrenceStatus,
): EventKind | null {
  if (current === incoming) {
    return null;
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
  /** When the last event (fired, resolved, reopened) happened. Repeats don't move it. */
  readonly lastEventAt: Date;
  readonly notificationCount: number;
};

export interface OccurrenceEvent {
  readonly id: number;
  readonly kind: EventKind;
  readonly recordedAt: Date;
}
