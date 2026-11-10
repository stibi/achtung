import { loadConfig } from "./config.ts";
import { openDatabase, ping } from "./db/client.ts";
import { migrateDatabase } from "./db/migrate.ts";
import { buildApp } from "./http/app.ts";
import { alertmanagerAlertsFrom } from "./services/home.ts";
import { servicesFor } from "./services/index.ts";
import { irmHeartbeatsFrom } from "./services/irm-heartbeats.ts";
import { reconcilerFor } from "./services/reconcile.ts";
import { silencesFrom } from "./services/silences.ts";
import { alertmanagerSource } from "./sources/alertmanager/index.ts";

const config = loadConfig();
const { pool, db } = openDatabase(config.databaseUrl);
const silences = silencesFrom(config.alertmanagers, {
  // Reads go on without that instance's silences; the client sees no silence.
  onReadError: (instance, error) =>
    app.log.warn({ instance, err: error }, "could not read silences from Alertmanager"),
});
const alerts = alertmanagerAlertsFrom(config.alertmanagers, {
  // The home view shows the instance as unreachable, with its last alerts if any.
  onReadError: (instance, error) =>
    app.log.warn({ instance, err: error }, "could not read alerts from Alertmanager"),
});
const heartbeats = irmHeartbeatsFrom(
  config.irm,
  new Map(
    [...config.alertmanagers].flatMap(([instance, { irmIntegrationId }]) =>
      irmIntegrationId === null ? [] : [[instance, irmIntegrationId] as const],
    ),
  ),
  {
    // The home view shows the heartbeat as unknown, or its last status, with the error.
    onReadError: (integrationId, error) =>
      app.log.warn({ integrationId, err: error }, "could not read heartbeats from Grafana IRM"),
  },
);
const app = buildApp({
  logLevel: config.logLevel,
  sources: [alertmanagerSource],
  services: servicesFor(db, { silences, alerts, heartbeats }),
  checkReady: () => ping(pool),
});

// Resolves what is gone from its Alertmanager (ADR 0014). One run at a time: a slow one
// delays the next rather than overlapping it.
const reconciler = reconcilerFor(db, alerts);
const reconcileEveryMs = 60_000;
let reconciling: ReturnType<typeof setTimeout> | undefined;
let running: Promise<void> | undefined;
let stopping = false;
function scheduleReconcile(): void {
  if (!stopping) {
    reconciling = setTimeout(() => {
      running = reconcile();
    }, reconcileEveryMs);
  }
}
async function reconcile(): Promise<void> {
  try {
    const { resolved } = await reconciler.run();
    if (resolved.length > 0) {
      app.log.info({ occurrences: resolved }, "resolved occurrences gone from Alertmanager");
    }
  } catch (error) {
    app.log.error({ err: error }, "could not resolve occurrences gone from Alertmanager");
  }
  scheduleReconcile();
}

// An idle connection that breaks must not crash the process; the pool reconnects.
pool.on("error", (error) => app.log.error({ err: error }, "database connection failed"));

async function shutdown(signal: NodeJS.Signals): Promise<void> {
  app.log.info({ signal }, "shutting down");
  stopping = true;
  clearTimeout(reconciling);
  // A run in progress finishes before the pool closes under it.
  await running;
  await app.close();
  await pool.end();
}

process.once("SIGTERM", (signal) => void shutdown(signal));
process.once("SIGINT", (signal) => void shutdown(signal));

await migrateDatabase(pool);
app.log.info("database migrated");
await app.listen({ host: config.host, port: config.port });
scheduleReconcile();
