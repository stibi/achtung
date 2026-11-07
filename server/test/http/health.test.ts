import { describe, expect, it, onTestFinished } from "vitest";
import { buildApp } from "../../src/http/app.ts";
import { unusedServices } from "../app.ts";

function testApp(checkReady: () => Promise<void>, logLines: Record<string, unknown>[] = []) {
  const app = buildApp({
    logLevel: "info",
    logStream: { write: (line) => logLines.push(JSON.parse(line) as Record<string, unknown>) },
    sources: [],
    services: unusedServices,
    checkReady,
  });
  onTestFinished(() => app.close());
  return app;
}

describe("health endpoints", () => {
  it.each(["/healthz", "/readyz"])("%s returns ok", async (path) => {
    const app = testApp(async () => {});

    const response = await app.inject({ method: "GET", url: path });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: "ok" });
  });

  it("is not ready while the database is unavailable", async () => {
    const app = testApp(() => Promise.reject(new Error("connection refused")));

    const live = await app.inject({ method: "GET", url: "/healthz" });
    const ready = await app.inject({ method: "GET", url: "/readyz" });

    expect(live.statusCode).toBe(200);
    expect(ready.statusCode).toBe(503);
    expect(ready.json()).toEqual({ status: "unavailable" });
  });

  it("keeps probe requests out of the log, but not a failed readiness check", async () => {
    const logLines: Record<string, unknown>[] = [];
    const app = testApp(() => Promise.reject(new Error("connection refused")), logLines);

    await app.inject({ method: "GET", url: "/healthz" });
    await app.inject({ method: "GET", url: "/readyz" });
    await app.inject({ method: "GET", url: "/no-such-route" });

    // The probes leave only the failure; the route after them is still logged.
    expect(logLines.map((line) => line["msg"]).slice(0, 2)).toEqual([
      "not ready",
      "incoming request",
    ]);
  });
});
