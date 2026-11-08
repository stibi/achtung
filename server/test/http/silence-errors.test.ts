import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, unreachableUrl } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson } from "../api.ts";
import { appWithDatabase, type TestAppOptions } from "../app.ts";

async function appWithAlert(options: TestAppOptions = {}) {
  const { app, services } = await appWithDatabase(options);
  await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");
  const { body } = await getJson(app, "/api/occurrences");
  return { app, id: body.occurrences[0].id as number };
}

function post(app: Awaited<ReturnType<typeof appWithAlert>>["app"], id: number, body: object) {
  return app.inject({ method: "POST", url: `/api/occurrences/${id}/silence`, body });
}

describe("POST /api/occurrences/{id}/silence, when it can't", () => {
  it.each([
    ["shorter than a minute", { durationSeconds: 59 }],
    ["longer than 30 days", { durationSeconds: 30 * 24 * 3600 + 1 }],
    ["not whole seconds", { durationSeconds: 90.5 }],
    ["missing", {}],
  ])("rejects a duration %s", async (_, body) => {
    const stub = await startAlertmanagerStub();
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
    });

    const response = await post(app, id, body);

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: expect.stringContaining("durationSeconds") });
    expect(stub.requests.filter((request) => request.method === "POST")).toEqual([]);
  });

  it("answers 404 for an occurrence it doesn't have", async () => {
    const { app, id } = await appWithAlert();

    const response = await post(app, id + 1000, { durationSeconds: 3600 });

    expect(response.statusCode).toBe(404);
  });

  it("answers 409 when the instance has no Alertmanager configured", async () => {
    const { app, id } = await appWithAlert({
      alertmanagers: { other: { url: "http://127.0.0.1:1", basicAuth: null } },
    });

    const response = await post(app, id, { durationSeconds: 3600 });

    expect(response.statusCode).toBe(409);
    expect(response.json()).toEqual({ error: "No Alertmanager is configured for instance lab" });
  });

  it("answers 502 with Alertmanager's reason when it refuses the silence", async () => {
    const stub = await startAlertmanagerStub();
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
    });
    stub.fail(400, "invalid label matcher\n");

    const response = await post(app, id, { durationSeconds: 3600 });

    expect(response.statusCode).toBe(502);
    expect(response.json()).toEqual({
      error: "Alertmanager answered 400: invalid label matcher",
    });
  });

  it("answers 502 when Alertmanager is unreachable", async () => {
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: await unreachableUrl(), basicAuth: null } },
    });

    const response = await post(app, id, { durationSeconds: 3600 });

    expect(response.statusCode).toBe(502);
    expect(response.json()).toEqual({ error: expect.stringContaining("unreachable") });
  });
});

describe("reading occurrences while an Alertmanager is down", () => {
  it("still answers, without silences, and reports the failure", async () => {
    const failures: string[] = [];
    const { app } = await appWithAlert({
      alertmanagers: { lab: { url: await unreachableUrl(), basicAuth: null } },
      silences: { onReadError: (instance, error) => failures.push(`${instance}: ${error.name}`) },
    });

    const { status, body } = await getJson(app, "/api/occurrences");

    expect(status).toBe(200);
    expect(body.occurrences[0].silencedUntil).toBeNull();
    expect(failures).toContain("lab: AlertmanagerError");
  });

  it("keeps showing the silences it last read", async () => {
    const stub = await startAlertmanagerStub();
    let now = new Date("2026-10-13T09:00:00Z");
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: () => now },
    });
    await post(app, id, { durationSeconds: 3600 });
    await getJson(app, "/api/occurrences");

    stub.fail(503, "down for maintenance");
    now = new Date("2026-10-13T09:01:00Z");

    const { body } = await getJson(app, "/api/occurrences");
    expect(body.occurrences[0].silencedUntil).toBe("2026-10-13T10:00:00.000Z");
  });
});

describe("silences Achtung reads while it creates one", () => {
  it("doesn't let a read that started before the silence hide it", async () => {
    const stub = await startAlertmanagerStub();
    let now = new Date("2026-10-13T09:00:00Z");
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: () => now },
    });
    now = new Date("2026-10-13T09:01:00Z");
    const hold = stub.holdNextRead();
    const slowRead = getJson(app, "/api/occurrences");
    await hold.arrived;

    await post(app, id, { durationSeconds: 3600 });
    hold.release();
    await slowRead;

    const { body } = await getJson(app, "/api/occurrences");
    expect(body.occurrences[0].silencedUntil).toBe("2026-10-13T10:01:00.000Z");
  });
});

describe("an Alertmanager that is down", () => {
  it("is asked again only after 30 seconds", async () => {
    const stub = await startAlertmanagerStub();
    let now = new Date("2026-10-13T09:00:00Z");
    const { app } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: () => now },
    });
    stub.fail(503, "down");
    now = new Date("2026-10-13T09:01:00Z");
    const reads = () => stub.requests.filter((request) => request.method === "GET").length;
    const before = reads();

    await getJson(app, "/api/occurrences");
    await getJson(app, "/api/occurrences");

    expect(reads() - before).toBe(1);
  });

  it("degrades, not fails, when the connection drops mid-answer", async () => {
    const stub = await startAlertmanagerStub();
    stub.breakBodies();
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
    });

    expect((await getJson(app, "/api/occurrences")).status).toBe(200);
    expect((await post(app, id, { durationSeconds: 3600 })).statusCode).toBe(502);
  });
});

describe("a read that fails right after Achtung created a silence", () => {
  it("keeps the silences read before", async () => {
    const stub = await startAlertmanagerStub();
    stub.silences.push({
      id: "from-the-ui",
      status: { state: "active" },
      matchers: [{ name: "namespace", value: "example-prod", isRegex: false }],
      startsAt: "2026-10-13T08:00:00Z",
      endsAt: "2026-10-13T20:00:00Z",
      createdBy: "someone",
      comment: "maintenance",
    });
    const { app, id } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: () => new Date("2026-10-13T09:00:00Z") },
    });
    stub.failReads(503, "down");

    await post(app, id, { durationSeconds: 60 });

    const { body } = await getJson(app, "/api/occurrences");
    expect(body.occurrences[0].silencedUntil).toBe("2026-10-13T20:00:00.000Z");
  });
});
