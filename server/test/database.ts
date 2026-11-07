import { randomUUID } from "node:crypto";
import { inject, onTestFinished } from "vitest";
import { type DatabaseConnection, openDatabase } from "../src/db/client.ts";
import { databaseUrl, templateDatabase } from "./postgres.ts";

/**
 * A fresh database for one test, dropped when the test finishes. Migrated and empty by
 * default; `{ migrated: false }` gives one without any tables.
 */
export async function createTestDatabase({ migrated = true } = {}): Promise<DatabaseConnection> {
  const serverUrl = inject("postgresUrl");
  const name = `test_${randomUUID().replaceAll("-", "")}`;
  const admin = openDatabase(serverUrl);
  await admin.pool.query(
    `create database ${name} template ${migrated ? templateDatabase : "template0"}`,
  );

  const connection = openDatabase(databaseUrl(serverUrl, name));
  onTestFinished(async () => {
    await connection.pool.end();
    await admin.pool.query(`drop database ${name}`);
    await admin.pool.end();
  });
  return connection;
}

/**
 * Opens `count` pool connections up front. Concurrency tests need this: on a cold pool,
 * connection setup staggers the transactions so much that they never actually overlap.
 */
export async function openConnections(
  connection: DatabaseConnection,
  count: number,
): Promise<void> {
  await Promise.all(
    Array.from({ length: count }, () => connection.pool.query("select pg_sleep(0.05)")),
  );
}
