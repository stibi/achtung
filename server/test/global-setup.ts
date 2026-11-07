import { PostgreSqlContainer } from "@testcontainers/postgresql";
import type { TestProject } from "vitest/node";
import { openDatabase } from "../src/db/client.ts";
import { migrateDatabase } from "../src/db/migrate.ts";
import { databaseUrl, templateDatabase } from "./postgres.ts";

declare module "vitest" {
  export interface ProvidedContext {
    /** Admin connection to the test Postgres; tests clone `templateDatabase` from it. */
    postgresUrl: string;
  }
}

// One real Postgres for the whole run (never a mock). The migrated template is cloned
// for every test, which is much faster than migrating each time.
export async function setup(project: TestProject): Promise<() => Promise<void>> {
  const container = await new PostgreSqlContainer("postgres:18-alpine").start();
  const admin = openDatabase(container.getConnectionUri());
  await admin.pool.query(`create database ${templateDatabase}`);
  await admin.pool.end();

  const template = openDatabase(databaseUrl(container.getConnectionUri(), templateDatabase));
  await migrateDatabase(template.pool);
  await template.pool.end();

  project.provide("postgresUrl", container.getConnectionUri());
  return async () => {
    await container.stop();
  };
}
