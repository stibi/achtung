import {
  and,
  asc,
  count,
  desc,
  eq,
  getTableColumns,
  gt,
  inArray,
  isNotNull,
  max,
  ne,
  or,
  type SQL,
  sql,
} from "drizzle-orm";
import { z } from "zod";
import type { AlertState } from "../domain/alert.ts";
import type { ChannelRef, ChannelSlug, InstanceName } from "../domain/channel.ts";
import type { Occurrence, OccurrenceEvent } from "../domain/occurrence.ts";
import type { Database, Transaction } from "./client.ts";
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
  instance: channels.instance,
  channel: channels.slug,
};

type OccurrenceRow = Awaited<ReturnType<typeof selectOccurrences>>[number];

function toOccurrence(row: OccurrenceRow): Occurrence {
  const { channelId: _, status, endsAt, instance, channel, ...fields } = row;
  return {
    ...fields,
    ...stateOf(row.id, status, endsAt),
    instance: instance as InstanceName,
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
      instance: channels.instance,
      slug: channels.slug,
      firing: count(sql`case when ${occurrences.status} = 'firing' then 1 end`),
      lastEventAt: max(occurrences.lastEventAt),
    })
    .from(channels)
    .leftJoin(occurrences, eq(occurrences.channelId, channels.id))
    .groupBy(channels.id)
    .orderBy(asc(channels.instance), asc(channels.slug));
}

export async function findChannelId(
  db: Database,
  { instance, slug }: ChannelRef,
): Promise<number | null> {
  const [row] = await db
    .select({ id: channels.id })
    .from(channels)
    .where(and(eq(channels.instance, instance), eq(channels.slug, slug)));
  return row?.id ?? null;
}

/**
 * Every instance that has a channel of this name, for the old URLs without an instance.
 * In a transaction, the rows stay locked until it ends: moving a channel to another
 * instance waits for the ingest, or the ingest waits and reads where it moved.
 */
export async function findInstancesWithChannel(
  db: Database | Transaction,
  slug: ChannelSlug,
): Promise<InstanceName[]> {
  const rows = await db
    .select({ instance: channels.instance })
    .from(channels)
    .where(eq(channels.slug, slug))
    .for("key share");
  return rows.map((row) => row.instance as InstanceName);
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
      eq(channels.instance, occurrence.instance),
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

/** Every firing occurrence, the longest firing first. */
export async function listFiringOccurrences(db: Database): Promise<Occurrence[]> {
  const rows = await selectOccurrences(db, eq(occurrences.status, "firing")).orderBy(
    asc(occurrences.startsAt),
    asc(occurrences.id),
  );
  return rows.map(toOccurrence);
}

/**
 * A source's occurrences, in any status, with an event after the time given for their
 * instance. Each instance is bounded by its own time, so one far in the past costs only
 * that instance's history.
 */
export async function listOccurrencesChangedSince(
  db: Database,
  source: string,
  since: readonly { readonly instance: string; readonly at: Date }[],
) {
  if (since.length === 0) {
    return [];
  }
  const rows = await db
    .select({
      instance: channels.instance,
      source: occurrences.source,
      sourceKey: occurrences.sourceKey,
      startsAt: occurrences.startsAt,
      lastEventAt: occurrences.lastEventAt,
    })
    .from(occurrences)
    .innerJoin(channels, eq(channels.id, occurrences.channelId))
    .where(
      and(
        eq(occurrences.source, source),
        or(
          ...since.map(({ instance, at }) =>
            and(eq(channels.instance, instance), gt(occurrences.lastEventAt, at)),
          ),
        ),
      ),
    )
    .orderBy(desc(occurrences.lastEventAt), desc(occurrences.id));
  return rows.map((row) => ({ ...row, instance: row.instance as InstanceName }));
}

/** The receivers that have delivered to each instance's channels (ADR 0010). */
export async function listReceivers(
  db: Database,
): Promise<{ instance: InstanceName; receiver: string }[]> {
  const rows = await db
    .selectDistinct({ instance: channels.instance, receiver: channels.receiver })
    .from(channels)
    .where(isNotNull(channels.receiver));
  return rows.flatMap(({ instance, receiver }) =>
    receiver === null ? [] : [{ instance: instance as InstanceName, receiver }],
  );
}

/**
 * The alerts with the most fired, reopened and resent events since `since`, at least
 * `minEvents` of them, most first, each with its newest occurrence. Ties go to the alert
 * whose latest event is newer.
 */
export async function listNoisiestAlerts(
  db: Database,
  { since, minEvents, limit }: { since: Date; minEvents: number; limit: number },
): Promise<{ occurrence: Occurrence; events: number }[]> {
  const identity = [occurrences.channelId, occurrences.source, occurrences.sourceKey] as const;
  const noisiest = await db
    .select({
      channelId: occurrences.channelId,
      source: occurrences.source,
      sourceKey: occurrences.sourceKey,
      events: count(),
    })
    .from(events)
    .innerJoin(occurrences, eq(occurrences.id, events.occurrenceId))
    .where(and(gt(events.recordedAt, since), inArray(events.kind, ["fired", "reopened", "resent"])))
    .groupBy(...identity)
    .having(sql`count(*) >= ${minEvents}`)
    .orderBy(
      desc(count()),
      desc(max(events.recordedAt)),
      asc(occurrences.channelId),
      asc(occurrences.sourceKey),
    )
    .limit(limit);
  if (noisiest.length === 0) {
    return [];
  }
  // The newest occurrence of each, through the identity index's leading columns.
  const newest = await db
    .selectDistinctOn([...identity], occurrenceColumns)
    .from(occurrences)
    .innerJoin(channels, eq(channels.id, occurrences.channelId))
    .where(
      sql`(${occurrences.channelId}, ${occurrences.source}, ${occurrences.sourceKey}) in (${sql.join(
        noisiest.map((alert) => sql`(${alert.channelId}, ${alert.source}, ${alert.sourceKey})`),
        sql`, `,
      )})`,
    )
    .orderBy(...identity, desc(occurrences.startsAt));
  const keyOf = (alert: { channelId: number; source: string; sourceKey: string }) =>
    JSON.stringify([alert.channelId, alert.source, alert.sourceKey]);
  const byIdentity = new Map(newest.map((row) => [keyOf(row), toOccurrence(row)]));
  return noisiest.flatMap((alert) => {
    const occurrence = byIdentity.get(keyOf(alert));
    return occurrence === undefined ? [] : [{ occurrence, events: alert.events }];
  });
}
