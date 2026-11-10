import type { FastifyInstance } from "fastify";
import { onTestFinished } from "vitest";
import type { AlertmanagerEndpoint } from "../src/clients/alertmanager.ts";
import type { IrmEndpoint } from "../src/clients/irm.ts";
import { buildApp, type Services } from "../src/http/app.ts";
import { type AlertmanagerAlertsOptions, alertmanagerAlertsFrom } from "../src/services/home.ts";
import { servicesFor } from "../src/services/index.ts";
import { type IrmHeartbeatsOptions, irmHeartbeatsFrom } from "../src/services/irm-heartbeats.ts";
import { type Reconciler, reconcilerFor } from "../src/services/reconcile.ts";
import { type SilencesOptions, silencesFrom } from "../src/services/silences.ts";
import { alertmanagerSource } from "../src/sources/alertmanager/index.ts";
import { createTestDatabase } from "./database.ts";

const unused = () => Promise.reject(new Error("this test uses no services"));

/** For tests that never reach a service (health checks, the OpenAPI document). */
export const unusedServices: Services = {
  ingest: unused,
  listChannels: unused,
  listChannelOccurrences: unused,
  listOccurrences: unused,
  getOccurrence: unused,
  silenceOccurrence: unused,
  unsilenceOccurrence: unused,
  getHome: unused,
  listAlertmanagerAlerts: unused,
  getIgnoredAlertNames: unused,
  setIgnoredAlertNames: unused,
};

export interface TestAppOptions {
  /** Log lines at warn and above. */
  readonly logLines?: Record<string, unknown>[];
  /** Each instance's Alertmanager, e.g. a stub (test/alertmanager-stub.ts). None by default. */
  readonly alertmanagers?: Readonly<Record<string, AlertmanagerEndpoint>>;
  readonly silences?: SilencesOptions;
  readonly alerts?: AlertmanagerAlertsOptions;
  /** Grafana IRM, e.g. a stub (test/irm-stub.ts), and each instance's integration ID. None by default. */
  readonly irm?: {
    /** Null: integrations configured, but not IRM itself. */
    readonly endpoint: IrmEndpoint | null;
    readonly integrations: Readonly<Record<string, string>>;
    readonly options?: IrmHeartbeatsOptions;
  };
  /** The clock of the services themselves, e.g. the home view's last 24 hours. */
  readonly now?: () => Date;
}

/** The real app on a fresh test database. */
export async function appWithDatabase(
  options: TestAppOptions = {},
): Promise<{ app: FastifyInstance; services: Services; reconciler: Reconciler }> {
  const logLines = options.logLines ?? [];
  const { db } = await createTestDatabase();
  const endpoints = new Map(Object.entries(options.alertmanagers ?? {}));
  const alerts = alertmanagerAlertsFrom(endpoints, options.alerts);
  const services = servicesFor(
    db,
    {
      silences: silencesFrom(endpoints, options.silences),
      alerts,
      heartbeats: irmHeartbeatsFrom(
        options.irm?.endpoint ?? null,
        new Map(Object.entries(options.irm?.integrations ?? {})),
        options.irm?.options,
      ),
    },
    options.now,
  );
  const app = buildApp({
    logLevel: "warn",
    logStream: { write: (line) => logLines.push(JSON.parse(line) as Record<string, unknown>) },
    sources: [alertmanagerSource],
    services,
    checkReady: async () => {},
  });
  onTestFinished(() => app.close());
  return { app, services, reconciler: reconcilerFor(db, alerts, options.now) };
}
