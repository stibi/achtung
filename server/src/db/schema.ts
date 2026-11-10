import { sql } from "drizzle-orm";
import {
  bigint,
  check,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  text,
  timestamp,
  unique,
} from "drizzle-orm/pg-core";
import type { AlertLink } from "../domain/alert.ts";

// Change this file, then run `pnpm run db:generate` and commit the generated migration.
// Column names are snake_case in the database (see `casing` in client.ts).

const timestamptz = () => timestamp({ withTimezone: true, mode: "date" });

export const channels = pgTable(
  "channels",
  {
    id: integer().primaryKey().generatedAlwaysAsIdentity(),
    // Rows from before instances existed get the default instance (ADR 0006).
    instance: text().notNull().default("default"),
    slug: text().notNull(),
    // What last delivered to the channel, e.g. Alertmanager's receiver (ADR 0010); null
    // until a notification names one.
    receiver: text(),
    createdAt: timestamptz().notNull(),
  },
  (table) => [unique("channels_instance_slug").on(table.instance, table.slug)],
);

export const occurrenceStatus = pgEnum("occurrence_status", ["firing", "resolved"]);
export const severity = pgEnum("severity", ["critical", "warning", "info", "unknown"]);
export const eventKind = pgEnum("event_kind", ["fired", "resolved", "reopened", "resent"]);
// Why Achtung recorded an event itself, rather than because a notification said so.
export const eventCause = pgEnum("event_cause", ["vanished"]);

/** One occurrence of an alert: its identity plus startsAt (docs/architecture.md). */
export const occurrences = pgTable(
  "occurrences",
  {
    id: bigint({ mode: "number" }).primaryKey().generatedAlwaysAsIdentity(),
    channelId: integer()
      .notNull()
      .references(() => channels.id),
    source: text().notNull(),
    sourceKey: text().notNull(),
    startsAt: timestamptz().notNull(),
    status: occurrenceStatus().notNull(),
    endsAt: timestamptz(),
    severity: severity().notNull(),
    title: text().notNull(),
    summary: text(),
    labels: jsonb().$type<Record<string, string>>().notNull(),
    annotations: jsonb().$type<Record<string, string>>().notNull(),
    links: jsonb().$type<readonly AlertLink[]>().notNull(),
    firstReceivedAt: timestamptz().notNull(),
    lastReceivedAt: timestamptz().notNull(),
    // The default only serves replicas from before this column during a rolling deploy;
    // current code always sets it.
    lastEventAt: timestamptz().notNull().defaultNow(),
    // The kind of that last event, so a list can show a resend without loading events.
    // Migration 0004 fills it in for existing rows; the default serves inserts from older
    // replicas.
    lastEventKind: eventKind().notNull().default("fired"),
    notificationCount: integer().notNull().default(1),
  },
  (table) => [
    // Also serves "every occurrence of this alert": its leading columns are the identity.
    unique("occurrences_identity").on(
      table.channelId,
      table.source,
      table.sourceKey,
      table.startsAt,
    ),
    // Channel lists, newest change first, paginated by (last_event_at, id).
    index("occurrences_channel_last_event").on(
      table.channelId,
      table.lastEventAt.desc(),
      table.id.desc(),
    ),
    // The cross-channel list (GET /api/occurrences), in the same order.
    index("occurrences_last_event").on(table.lastEventAt.desc(), table.id.desc()),
    // ...and that list filtered by status (?status=), so firing rows aren't found by
    // scanning past every resolved one.
    index("occurrences_status_last_event").on(
      table.status,
      table.lastEventAt.desc(),
      table.id.desc(),
    ),
    check(
      "occurrences_end_matches_status",
      sql`(${table.status} = 'firing') = (${table.endsAt} is null)`,
    ),
  ],
);

export const events = pgTable(
  "events",
  {
    id: bigint({ mode: "number" }).primaryKey().generatedAlwaysAsIdentity(),
    occurrenceId: bigint({ mode: "number" })
      .notNull()
      .references(() => occurrences.id),
    kind: eventKind().notNull(),
    // Null: a notification caused it. `vanished`: Achtung resolved the occurrence because
    // its Alertmanager no longer had it (ADR 0014).
    cause: eventCause(),
    recordedAt: timestamptz().notNull(),
  },
  (table) => [
    index("events_occurrence_id").on(table.occurrenceId),
    // The home view counts the last day's events (noisiest alerts). Without it, every
    // refresh would scan the whole history, which only grows.
    index("events_recorded_at").on(table.recordedAt),
  ],
);

/**
 * Alert names the Home views leave out (ADR 0011): one list shared by every client, as
 * there are no users (ADR 0002). Migration 0006 seeds it.
 */
export const ignoredAlertNames = pgTable("ignored_alert_names", {
  // An alertname, matched exactly and case-sensitively.
  name: text().primaryKey(),
  createdAt: timestamptz().notNull(),
});
