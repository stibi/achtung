import { and, asc, count, desc, eq, getTableColumns, max, ne, type SQL, sql } from "drizzle-orm";
import { z } from "zod";
import type { AlertState } from "../domain/alert.ts";
import type { ChannelSlug } from "../domain/channel.ts";
import type { Occurrence, OccurrenceEvent } from "../domain/occurrence.ts";
import type { Database } from "./client.ts";
import { channels, events, occurrences } from "./schema.ts";

// Mirrors services/inbox.ts OccurrenceFilter structurally; db/ can't import services.
interface OccurrenceFilter {
  readonly status: AlertState["status"] | null;
  readonly after: { readonly lastEventAt: Date; readonly id: number } | null;
  readonly limit: number;
}

// JSON columns are parsed on the way out (golden principle 3); everything else is typed
// by the schema and its constraints.
const labelSet = z.record(z.string(), z.string());
const links = z.array(
  z.object({ kind: z.enum(["source", "runbook", "dashboard"]), url: z.string() }),
);

const occurrenceColumns = {
  ...getTableColumns(occurrences),
  channel: channels.slug,
};

type OccurrenceRow = Awaited<ReturnType<typeof selectOccurrences>>[number];

function toOccurrence(row: OccurrenceRow): Occurrence {
  const { channelId: _, status, endsAt, channel, ...fields } = row;
  return {
    ...fields,
    ...stateOf(row.id, status, endsAt),
    channel: channel as ChannelSlug,
    labels: labelSet.parse(fields.labels),
    annotations: labelSet.parse(fields.annotations),
    links: links.parse(fields.links),
  };
}

function stateOf(id: number, status: AlertState["status"], endsAt: Date | null): AlertState {
  if (status === "firing") {
    return { status, endsAt: null };
  }
  if (endsAt === null) {
    throw new Error(`Resolved occurrence ${id} has no end, despite the check constraint`);
  }
  return { status, endsAt };
}

function selectOccurrences(db: Database, where: SQL | undefined) {
  return db
    .select(occurrenceColumns)
    .from(occurrences)
    .innerJoin(channels, eq(channels.id, occurrences.channelId))
    .where(where);
}

export function listChannelOverviews(db: Database) {
  return db
    .select({
      slug: channels.slug,
      firing: count(sql`case when ${occurrences.status} = 'firing' then 1 end`),
      lastEventAt: max(occurrences.lastEventAt),
    })
    .from(channels)
    .leftJoin(occurrences, eq(occurrences.channelId, channels.id))
    .groupBy(channels.id)
    .orderBy(asc(channels.slug));
}

export async function findChannelId(db: Database, slug: ChannelSlug): Promise<number | null> {
  const [row] = await db.select({ id: channels.id }).from(channels).where(eq(channels.slug, slug));
  return row?.id ?? null;
}

/** Newest change first; `channelId` null lists every channel. */
export async function listOccurrences(
  db: Database,
  channelId: number | null,
  { status, after, limit }: OccurrenceFilter,
): Promise<Occurrence[]> {
  const rows = await selectOccurrences(
    db,
    and(
      channelId === null ? undefined : eq(occurrences.channelId, channelId),
      status === null ? undefined : eq(occurrences.status, status),
      after === null
        ? undefined
        : sql`(${occurrences.lastEventAt}, ${occurrences.id}) < (${after.lastEventAt}, ${after.id})`,
    ),
  )
    .orderBy(desc(occurrences.lastEventAt), desc(occurrences.id))
    .limit(limit);
  return rows.map(toOccurrence);
}

export async function findOccurrence(db: Database, id: number): Promise<Occurrence | null> {
  const [row] = await selectOccurrences(db, eq(occurrences.id, id));
  return row === undefined ? null : toOccurrence(row);
}

export function listEvents(db: Database, occurrenceId: number): Promise<OccurrenceEvent[]> {
  return db
    .select({ id: events.id, kind: events.kind, recordedAt: events.recordedAt })
    .from(events)
    .where(eq(events.occurrenceId, occurrenceId))
    .orderBy(asc(events.id));
}

/** Other occurrences of the same alert (same identity, different start), newest first. */
export async function listOtherOccurrences(
  db: Database,
  occurrence: Occurrence,
  limit: number,
): Promise<Occurrence[]> {
  const rows = await selectOccurrences(
    db,
    and(
      eq(channels.slug, occurrence.channel),
      eq(occurrences.source, occurrence.source),
      eq(occurrences.sourceKey, occurrence.sourceKey),
      ne(occurrences.id, occurrence.id),
    ),
  )
    .orderBy(desc(occurrences.startsAt))
    .limit(limit);
  return rows.map(toOccurrence);
}
