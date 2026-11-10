import { and, eq, sql } from "drizzle-orm";
import type { IncomingAlert } from "../domain/alert.ts";
import type { ChannelRef } from "../domain/channel.ts";
import type { EventCause, EventKind } from "../domain/occurrence.ts";
import type { Transaction } from "./client.ts";
import { channels, events, occurrences } from "./schema.ts";

export interface OccurrenceKey {
  readonly channelId: number;
  readonly source: string;
  readonly alert: IncomingAlert;
}

/** The channel's id, created if needed, with `receiver` recorded when it names one. */
export async function findOrCreateChannel(
  tx: Transaction,
  { instance, slug }: ChannelRef,
  receiver: string | null,
  now: Date,
): Promise<number> {
  // DO NOTHING plus a read, not a no-op DO UPDATE: that would lock the channel row and
  // serialize every notification for the channel behind it.
  const [inserted] = await tx
    .insert(channels)
    .values({ instance, slug, receiver, createdAt: now })
    .onConflictDoNothing()
    .returning({ id: channels.id });
  if (inserted !== undefined) {
    return inserted.id;
  }
  const [existing] = await tx
    .select({ id: channels.id, receiver: channels.receiver })
    .from(channels)
    .where(and(eq(channels.instance, instance), eq(channels.slug, slug)));
  if (existing === undefined) {
    throw new Error(`Channel ${instance}/${slug} conflicted on insert but does not exist`);
  }
  // Only a change writes, and so locks the row; the receiver rarely changes. The condition
  // is repeated in the update, so concurrent deliveries that both saw a change write once.
  if (receiver !== null && receiver !== existing.receiver) {
    await tx
      .update(channels)
      .set({ receiver })
      .where(
        and(eq(channels.id, existing.id), sql`${channels.receiver} is distinct from ${receiver}`),
      );
  }
  return existing.id;
}

function alertFields(alert: IncomingAlert) {
  return {
    status: alert.status,
    endsAt: alert.endsAt,
    severity: alert.severity,
    title: alert.title,
    summary: alert.summary,
    labels: alert.labels,
    annotations: alert.annotations,
    links: alert.links,
  };
}

/** Inserts a new occurrence. Returns null when it already exists. */
export async function insertOccurrence(
  tx: Transaction,
  { channelId, source, alert }: OccurrenceKey,
  now: Date,
): Promise<number | null> {
  const [row] = await tx
    .insert(occurrences)
    .values({
      channelId,
      source,
      sourceKey: alert.sourceKey,
      startsAt: alert.startsAt,
      ...alertFields(alert),
      firstReceivedAt: now,
      lastReceivedAt: now,
      // Every new occurrence gets an event (fired, or resolved when the firing was missed).
      lastEventAt: now,
    })
    .onConflictDoNothing()
    .returning({ id: occurrences.id });
  return row?.id ?? null;
}

/** Locks an existing occurrence until the transaction ends and returns its current state. */
export async function lockOccurrence(tx: Transaction, { channelId, source, alert }: OccurrenceKey) {
  const [row] = await tx
    .select({
      id: occurrences.id,
      status: occurrences.status,
      lastEventAt: occurrences.lastEventAt,
    })
    .from(occurrences)
    .where(
      and(
        eq(occurrences.channelId, channelId),
        eq(occurrences.source, source),
        eq(occurrences.sourceKey, alert.sourceKey),
        eq(occurrences.startsAt, alert.startsAt),
      ),
    )
    .for("update");
  if (row === undefined) {
    throw new Error(`Occurrence ${alert.sourceKey} vanished inside its transaction`);
  }
  return row;
}

export async function updateOccurrence(
  tx: Transaction,
  id: number,
  alert: IncomingAlert,
  now: Date,
): Promise<void> {
  await tx
    .update(occurrences)
    .set({
      ...alertFields(alert),
      lastReceivedAt: now,
      notificationCount: sql`${occurrences.notificationCount} + 1`,
    })
    .where(eq(occurrences.id, id));
}

export async function recordEvent(
  tx: Transaction,
  occurrenceId: number,
  kind: EventKind,
  now: Date,
  cause: EventCause | null = null,
): Promise<void> {
  await tx.insert(events).values({ occurrenceId, kind, cause, recordedAt: now });
  await tx
    .update(occurrences)
    .set({ lastEventAt: now, lastEventKind: kind })
    .where(eq(occurrences.id, occurrenceId));
}

/**
 * Resolves a firing occurrence that is gone from its Alertmanager (ADR 0014), ending it at
 * `endsAt`. Does nothing if it no longer fires or a notification arrived after
 * `lastReceivedAt`: the update's condition decides under the row lock, so it can't race an
 * ingest of the same occurrence. Returns whether it resolved it.
 */
export async function resolveVanished(
  tx: Transaction,
  id: number,
  { lastReceivedAt, endsAt }: { readonly lastReceivedAt: Date; readonly endsAt: Date },
  now: Date,
): Promise<boolean> {
  const [row] = await tx
    .update(occurrences)
    .set({ status: "resolved", endsAt })
    .where(
      and(
        eq(occurrences.id, id),
        eq(occurrences.status, "firing"),
        eq(occurrences.lastReceivedAt, lastReceivedAt),
      ),
    )
    .returning({ id: occurrences.id });
  if (row === undefined) {
    return false;
  }
  await recordEvent(tx, id, "resolved", now, "vanished");
  return true;
}
