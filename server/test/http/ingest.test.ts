import { describe, expect, it, onTestFinished } from "vitest";
import { buildApp } from "../../src/http/app.ts";
import { ingestNotification } from "../../src/services/ingest.ts";
import { alertmanagerSource } from "../../src/sources/alertmanager/index.ts";
import { createTestDatabase } from "../database.ts";
import { loadFixture } from "../fixtures.ts";

async function testApp(logLines: Record<string, unknown>[] = []) {
  const { db } = await createTestDatabase();
  const app = buildApp({
    logLevel: "warn",
    logStream: { write: (line) => logLines.push(JSON.parse(line) as Record<string, unknown>) },
    sources: [alertmanagerSource],
    ingest: (notification) => ingestNotification(db, notification),
    checkReady: async () => {},
  });
  onTestFinished(() => app.close());
  return app;
}

const firing = loadFixture("alertmanager", "firing") as object;

describe("POST /ingest/alertmanager/{channel}", () => {
  it("ingests a notification and reports what was new", async () => {
    const app = await testApp();

    const first = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/example-prod",
      body: firing,
    });
    const repeat = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/example-prod",
      body: firing,
    });

    expect(first.statusCode).toBe(200);
    expect(first.json()).toEqual({ alerts: 2, new: 2, resolved: 0 });
    expect(repeat.json()).toEqual({ alerts: 2, new: 0, resolved: 0 });
  });

  it("rejects a payload the source cannot parse and logs it", async () => {
    const logLines: Record<string, unknown>[] = [];
    const app = await testApp(logLines);

    const response = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/example-prod",
      body: { ...firing, version: "3" },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: expect.stringContaining("version") });
    expect(logLines).toContainEqual(
      expect.objectContaining({
        msg: "rejected invalid payload",
        channel: "example-prod",
        body: expect.objectContaining({ version: "3" }),
      }),
    );
  });

  it("warns when the source dropped alerts from the notification", async () => {
    const logLines: Record<string, unknown>[] = [];
    const app = await testApp(logLines);

    const response = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/example-prod",
      body: { ...firing, truncatedAlerts: 3 },
    });

    expect(response.statusCode).toBe(200);
    expect(logLines).toContainEqual(
      expect.objectContaining({ msg: expect.stringContaining("dropped"), truncatedAlerts: 3 }),
    );
  });

  it.each(["Example-Prod", "-prod", "a".repeat(64), "prod_eu"])(
    "rejects the channel name %s",
    async (channel) => {
      const app = await testApp();

      const response = await app.inject({
        method: "POST",
        url: `/ingest/alertmanager/${channel}`,
        body: firing,
      });

      expect(response.statusCode).toBe(404);
      expect(response.json()).toEqual({ error: expect.stringContaining("must match") });
    },
  );

  it("does not accept sources it has no adapter for", async () => {
    const app = await testApp();

    const response = await app.inject({
      method: "POST",
      url: "/ingest/grafana/example-prod",
      body: firing,
    });

    expect(response.statusCode).toBe(404);
  });
});
