import { and, eq, sql } from "drizzle-orm";
import type { IncomingAlert } from "../domain/alert.ts";
import type { ChannelSlug } from "../domain/channel.ts";
import type { EventKind } from "../domain/occurrence.ts";
import type { Transaction } from "./client.ts";
import { channels, events, occurrences } from "./schema.ts";

export interface OccurrenceKey {
  readonly channelId: number;
  readonly source: string;
  readonly alert: IncomingAlert;
}

export async function findOrCreateChannel(
  tx: Transaction,
  slug: ChannelSlug,
  now: Date,
): Promise<number> {
  // DO NOTHING plus a read, not a no-op DO UPDATE: that would lock the channel row and
  // serialize every notification for the channel behind it.
  const [inserted] = await tx
    .insert(channels)
    .values({ slug, createdAt: now })
    .onConflictDoNothing()
    .returning({ id: channels.id });
  if (inserted !== undefined) {
    return inserted.id;
  }
  const [existing] = await tx
    .select({ id: channels.id })
    .from(channels)
    .where(eq(channels.slug, slug));
  if (existing === undefined) {
    throw new Error(`Channel ${slug} conflicted on insert but does not exist`);
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
    .select({ id: occurrences.id, status: occurrences.status })
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
): Promise<void> {
  await tx.insert(events).values({ occurrenceId, kind, recordedAt: now });
  await tx.update(occurrences).set({ lastEventAt: now }).where(eq(occurrences.id, occurrenceId));
}
