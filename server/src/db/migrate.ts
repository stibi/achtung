import { fileURLToPath } from "node:url";
import { drizzle } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import type { Pool } from "pg";

const migrationsFolder = fileURLToPath(new URL("../../drizzle", import.meta.url));

// Arbitrary, fixed key: every replica takes the same lock, so only one migrates at a time.
const migrationLock = 4_172_031;

/** Applies the pending migrations. Safe to run from several replicas starting together. */
export async function migrateDatabase(pool: Pool): Promise<void> {
  const client = await pool.connect();
  let failure: Error | undefined;
  try {
    await client.query("select pg_advisory_lock($1)", [migrationLock]);
    try {
      await migrate(drizzle({ client }), { migrationsFolder });
    } finally {
      await client.query("select pg_advisory_unlock($1)", [migrationLock]);
    }
  } catch (error) {
    failure = error instanceof Error ? error : new Error(String(error));
    throw error;
  } finally {
    // Passing the error makes the pool discard a connection that may be broken.
    client.release(failure);
  }
}
