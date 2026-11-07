import type { FastifyInstance } from "fastify";
import { onTestFinished } from "vitest";
import { buildApp, type Services } from "../src/http/app.ts";
import { servicesFor } from "../src/services/index.ts";
import { alertmanagerSource } from "../src/sources/alertmanager/index.ts";
import { createTestDatabase } from "./database.ts";

const unused = () => Promise.reject(new Error("this test uses no services"));

/** For tests that never reach a service (health checks, the OpenAPI document). */
export const unusedServices: Services = {
  ingest: unused,
  listChannels: unused,
  listChannelOccurrences: unused,
  getOccurrence: unused,
};

/** The real app on a fresh test database. Log lines at warn and above land in `logLines`. */
export async function appWithDatabase(
  logLines: Record<string, unknown>[] = [],
): Promise<{ app: FastifyInstance; services: Services }> {
  const { db } = await createTestDatabase();
  const services = servicesFor(db);
  const app = buildApp({
    logLevel: "warn",
    logStream: { write: (line) => logLines.push(JSON.parse(line) as Record<string, unknown>) },
    sources: [alertmanagerSource],
    services,
    checkReady: async () => {},
  });
  onTestFinished(() => app.close());
  return { app, services };
}
