import { describe, expect, it, onTestFinished } from "vitest";
import { buildApp } from "../../src/http/app.ts";

function testApp(checkReady: () => Promise<void>) {
  const app = buildApp({
    logLevel: "silent",
    sources: [],
    ingest: () => Promise.reject(new Error("ingest is not used by health checks")),
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
});
