import { loadConfig } from "./config.ts";
import { openDatabase, ping } from "./db/client.ts";
import { migrateDatabase } from "./db/migrate.ts";
import { buildApp } from "./http/app.ts";
import { ingestNotification } from "./services/ingest.ts";
import { alertmanagerSource } from "./sources/alertmanager/index.ts";

const config = loadConfig();
const { pool, db } = openDatabase(config.databaseUrl);
const app = buildApp({
  logLevel: config.logLevel,
  sources: [alertmanagerSource],
  ingest: (notification) => ingestNotification(db, notification),
  checkReady: () => ping(pool),
});

// An idle connection that breaks must not crash the process; the pool reconnects.
pool.on("error", (error) => app.log.error({ err: error }, "database connection failed"));

async function shutdown(signal: NodeJS.Signals): Promise<void> {
  app.log.info({ signal }, "shutting down");
  await app.close();
  await pool.end();
}

process.once("SIGTERM", (signal) => void shutdown(signal));
process.once("SIGINT", (signal) => void shutdown(signal));

await migrateDatabase(pool);
app.log.info("database migrated");
await app.listen({ host: config.host, port: config.port });
