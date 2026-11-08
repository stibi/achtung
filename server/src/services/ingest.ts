import type { Database, Transaction } from "../db/client.ts";
import {
  findOrCreateChannel,
  insertOccurrence,
  lockOccurrence,
  type OccurrenceKey,
  recordEvent,
  updateOccurrence,
} from "../db/occurrences.ts";
import { findInstancesWithChannel } from "../db/queries.ts";
import type { IncomingAlert } from "../domain/alert.ts";
import { type ChannelAddress, resolveChannel } from "../domain/channel.ts";
import { type EventKind, eventFor } from "../domain/occurrence.ts";

/** One webhook delivery from a source, already parsed into domain alerts. */
export interface Notification {
  readonly source: string;
  readonly channel: ChannelAddress;
  readonly alerts: readonly IncomingAlert[];
  readonly receivedAt: Date;
}

export interface IngestSummary {
  readonly alerts: number;
  /** Occurrences that started firing, or fired again, because of this notification. */
  readonly new: number;
  readonly resolved: number;
}

/**
 * Stores a notification in one transaction. Idempotent: delivering the same notification
 * again updates the stored occurrences but records no events and counts nothing as new.
 */
export function ingestNotification(
  db: Database,
  notification: Notification,
): Promise<IngestSummary> {
  return db.transaction(async (tx) => {
    const now = notification.receivedAt;
    const address = notification.channel;
    const instances =
      address.instance === null ? await findInstancesWithChannel(tx, address.slug) : [];
    const channelId = await findOrCreateChannel(tx, resolveChannel(address, instances), now);
    const recorded: (EventKind | null)[] = [];
    // Sequential on purpose: one transaction, and a fixed lock order (see inLockOrder).
    for (const alert of inLockOrder(notification.alerts)) {
      const key = { channelId, source: notification.source, alert };
      recorded.push(await ingestAlert(tx, key, now));
    }
    return {
      alerts: notification.alerts.length,
      new: recorded.filter((kind) => kind === "fired" || kind === "reopened").length,
      resolved: recorded.filter((kind) => kind === "resolved").length,
    };
  });
}

async function ingestAlert(
  tx: Transaction,
  key: OccurrenceKey,
  now: Date,
): Promise<EventKind | null> {
  const insertedId = await insertOccurrence(tx, key, now);
  if (insertedId !== null) {
    return record(tx, insertedId, eventFor(null, key.alert.status), now);
  }
  const current = await lockOccurrence(tx, key);
  await updateOccurrence(tx, current.id, key.alert, now);
  return record(tx, current.id, eventFor(current.status, key.alert.status), now);
}

async function record(
  tx: Transaction,
  occurrenceId: number,
  kind: EventKind | null,
  now: Date,
): Promise<EventKind | null> {
  if (kind !== null) {
    await recordEvent(tx, occurrenceId, kind, now);
  }
  return kind;
}

// Two notifications touching the same occurrences lock them in the same order, so
// concurrent deliveries (e.g. from an Alertmanager HA pair) wait instead of deadlocking.
function inLockOrder(alerts: readonly IncomingAlert[]): IncomingAlert[] {
  return alerts.toSorted(
    (a, b) => a.sourceKey.localeCompare(b.sourceKey) || a.startsAt.getTime() - b.startsAt.getTime(),
  );
}
