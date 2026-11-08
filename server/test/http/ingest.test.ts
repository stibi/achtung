import { describe, expect, it } from "vitest";
import { appWithDatabase } from "../app.ts";
import { loadFixture } from "../fixtures.ts";

async function testApp(logLines: Record<string, unknown>[] = []) {
  return (await appWithDatabase({ logLines })).app;
}

const firing = loadFixture("alertmanager", "firing") as object;

const url = "/ingest/alertmanager/lab/example-prod";

describe("POST /ingest/alertmanager/{instance}/{channel}", () => {
  it("ingests a notification and reports what was new", async () => {
    const app = await testApp();

    const first = await app.inject({
      method: "POST",
      url,
      body: firing,
    });
    const repeat = await app.inject({
      method: "POST",
      url,
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
      url,
      body: { ...firing, version: "3" },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: expect.stringContaining("version") });
    expect(logLines).toContainEqual(
      expect.objectContaining({
        msg: "rejected invalid payload",
        instance: "lab",
        channel: "example-prod",
        body: expect.objectContaining({ version: "3" }),
      }),
    );
  });

  it("says why a body that is not JSON was rejected", async () => {
    const app = await testApp();

    const response = await app.inject({
      method: "POST",
      url,
      headers: { "content-type": "application/json" },
      payload: '{"version": "4",',
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: expect.stringMatching(/JSON/i) });
  });

  it("warns when the source dropped alerts from the notification", async () => {
    const logLines: Record<string, unknown>[] = [];
    const app = await testApp(logLines);

    const response = await app.inject({
      method: "POST",
      url,
      body: { ...firing, truncatedAlerts: 3 },
    });

    expect(response.statusCode).toBe(200);
    expect(logLines).toContainEqual(
      expect.objectContaining({ msg: expect.stringContaining("dropped"), truncatedAlerts: 3 }),
    );
  });

  it.each(["Example-Prod", "-prod", "a".repeat(64), "prod_eu"])(
    "rejects the name %s for a channel or an instance",
    async (name) => {
      const app = await testApp();

      for (const path of [`lab/${name}`, `${name}/example-prod`, name]) {
        const response = await app.inject({
          method: "POST",
          url: `/ingest/alertmanager/${path}`,
          body: firing,
        });

        expect(response.statusCode).toBe(404);
        expect(response.json()).toEqual({ error: expect.stringContaining("must match") });
      }
    },
  );

  it("keeps a channel name apart in each instance", async () => {
    const { app } = await appWithDatabase();

    for (const instance of ["lab", "edge"]) {
      await app.inject({
        method: "POST",
        url: `/ingest/alertmanager/${instance}/ops`,
        body: firing,
      });
    }

    const channels = (await app.inject({ method: "GET", url: "/api/channels" })).json().channels;
    expect(channels).toEqual([
      expect.objectContaining({ instance: "edge", slug: "ops", firing: 2 }),
      expect.objectContaining({ instance: "lab", slug: "ops", firing: 2 }),
    ]);
  });

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

describe("POST /ingest/alertmanager/{channel}, without an instance", () => {
  async function post(app: Awaited<ReturnType<typeof testApp>>, path: string) {
    const response = await app.inject({
      method: "POST",
      url: `/ingest/alertmanager/${path}`,
      body: firing,
    });
    expect(response.statusCode).toBe(200);
  }

  async function channels(app: Awaited<ReturnType<typeof testApp>>) {
    const body = (await app.inject({ method: "GET", url: "/api/channels" })).json();
    return body.channels.map(
      (channel: { instance: string; slug: string; firing: number }) =>
        `${channel.instance}/${channel.slug}:${channel.firing}`,
    );
  }

  it("creates a name it has never seen in the default instance", async () => {
    const app = await testApp();

    await post(app, "ops");

    expect(await channels(app)).toEqual(["default/ops:2"]);
  });

  it("delivers to the one channel that has the name, in any instance", async () => {
    const app = await testApp();
    await post(app, "lab/ops");

    const response = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/ops",
      body: firing,
    });

    expect(response.json()).toEqual({ alerts: 2, new: 0, resolved: 0 });
    expect(await channels(app)).toEqual(["lab/ops:2"]);
  });

  it("uses the default instance when several instances have the name", async () => {
    const app = await testApp();
    await post(app, "lab/ops");
    await post(app, "edge/ops");

    await post(app, "ops");

    expect(await channels(app)).toEqual(["default/ops:2", "edge/ops:2", "lab/ops:2"]);
  });

  it("prefers the one named instance over a stray default channel of the same name", async () => {
    const app = await testApp();
    await post(app, "default/ops");
    await post(app, "lab/ops");

    const response = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/ops",
      body: firing,
    });

    expect(response.json()).toEqual({ alerts: 2, new: 0, resolved: 0 });
  });
});
