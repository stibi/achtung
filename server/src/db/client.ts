import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

export type Database = NodePgDatabase;
export type Transaction = Parameters<Parameters<Database["transaction"]>[0]>[0];

export interface DatabaseConnection {
  readonly pool: Pool;
  readonly db: Database;
}

export function openDatabase(url: string): DatabaseConnection {
  // Without a timeout, an unreachable (not refusing) database hangs requests and /readyz
  // until the OS gives up on the TCP connection.
  const pool = new Pool({ connectionString: url, connectionTimeoutMillis: 5_000 });
  return { pool, db: drizzle({ client: pool, casing: "snake_case" }) };
}

/** Throws when the database cannot answer a query. */
export async function ping(pool: Pool): Promise<void> {
  await pool.query("select 1");
}
