import { describe, expect, it } from "vitest";
import { migrateDatabase } from "../../src/db/migrate.ts";
import { createTestDatabase } from "../database.ts";

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
});
