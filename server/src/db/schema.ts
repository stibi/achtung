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

export const channels = pgTable("channels", {
  id: integer().primaryKey().generatedAlwaysAsIdentity(),
  slug: text().notNull().unique(),
  createdAt: timestamptz().notNull(),
});

export const occurrenceStatus = pgEnum("occurrence_status", ["firing", "resolved"]);
export const severity = pgEnum("severity", ["critical", "warning", "info", "unknown"]);
export const eventKind = pgEnum("event_kind", ["fired", "resolved", "reopened"]);

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
    recordedAt: timestamptz().notNull(),
  },
  (table) => [index("events_occurrence_id").on(table.occurrenceId)],
);
