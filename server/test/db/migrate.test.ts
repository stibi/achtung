import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { drizzle } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import type { Pool } from "pg";
import { describe, expect, it, onTestFinished } from "vitest";
import { migrateDatabase } from "../../src/db/migrate.ts";
import { createTestDatabase } from "../database.ts";

/** Applies only the first `count` committed migrations, to set up an older schema. */
async function migrateUpTo(pool: Pool, count: number): Promise<void> {
  const folder = await mkdtemp(join(tmpdir(), "achtung-migrations-"));
  onTestFinished(() => rm(folder, { recursive: true }));
  await cp(new URL("../../drizzle", import.meta.url), folder, { recursive: true });
  const journalPath = join(folder, "meta", "_journal.json");
  const journal = JSON.parse(await readFile(journalPath, "utf8")) as { entries: unknown[] };
  journal.entries = journal.entries.slice(0, count);
  await writeFile(journalPath, JSON.stringify(journal));
  await migrate(drizzle({ client: pool }), { migrationsFolder: folder });
}

describe("migrateDatabase", () => {
  it("lets several replicas migrate the same database at once", async () => {
    const { pool } = await createTestDatabase({ migrated: false });

    await Promise.all([migrateDatabase(pool), migrateDatabase(pool), migrateDatabase(pool)]);

    const tables = await pool.query<{ name: string }>(
      "select table_name as name from information_schema.tables where table_schema = 'public' order by 1",
    );
    expect(tables.rows.map((row) => row.name)).toEqual(["channels", "events", "occurrences"]);
  });

  it("does nothing on an up-to-date database", async () => {
    const { pool } = await createTestDatabase();

    await expect(migrateDatabase(pool)).resolves.toBeUndefined();
  });

  it("backfills last_event_at for occurrences stored before it existed", async () => {
    const { pool } = await createTestDatabase({ migrated: false });
    await migrateUpTo(pool, 1);
    await pool.query(`
      insert into channels (slug, created_at) values ('example-prod', now());
      insert into occurrences (channel_id, source, source_key, starts_at, status, severity, title,
        labels, annotations, links, first_received_at, last_received_at)
      values
        (1, 'alertmanager', 'with-events', '2026-10-13T08:00:00Z', 'firing', 'warning', 'A',
         '{}', '{}', '[]', '2026-10-13T08:01:00Z', '2026-10-13T09:00:00Z'),
        (1, 'alertmanager', 'without-events', '2026-10-13T08:00:00Z', 'firing', 'warning', 'B',
         '{}', '{}', '[]', '2026-10-13T08:01:00Z', '2026-10-13T09:30:00Z');
      insert into events (occurrence_id, kind, recorded_at)
      values (1, 'fired', '2026-10-13T08:01:00Z'), (1, 'resolved', '2026-10-13T08:20:00Z');
    `);

    await migrateDatabase(pool);

    const rows = await pool.query<{ key: string; last: Date }>(
      "select source_key as key, last_event_at as last from occurrences order by id",
    );
    expect(rows.rows).toEqual([
      { key: "with-events", last: new Date("2026-10-13T08:20:00Z") },
      { key: "without-events", last: new Date("2026-10-13T08:01:00Z") },
    ]);
  });
});
