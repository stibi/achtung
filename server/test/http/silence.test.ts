import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { startAlertmanagerStub } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson, targetDown } from "../api.ts";
import { appWithDatabase, type TestAppOptions } from "../app.ts";

const hour = 3600;

/** A test clock the silences read; ingest keeps its own fixed times. */
function clock(start: string) {
  let current = new Date(start);
  return {
    now: () => current,
    advance: (seconds: number) => {
      current = new Date(current.getTime() + seconds * 1000);
    },
  };
}

async function appWithAlert(options: TestAppOptions) {
  const { app, services } = await appWithDatabase(options);
  await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z", "ops", "lab");
  const { body } = await getJson(app, "/api/occurrences");
  const id = (title: string): number =>
    body.occurrences.find((occurrence: { title: string }) => occurrence.title === title).id;
  return { app, services, crashLoopId: id("KubePodCrashLooping") };
}

function silence(app: FastifyInstance, id: number, durationSeconds: unknown) {
  return app.inject({
    method: "POST",
    url: `/api/occurrences/${id}/silence`,
    body: { durationSeconds },
  });
}

describe("POST /api/occurrences/{id}/silence", () => {
  it("silences exactly this alert on its instance's Alertmanager", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock("2026-10-13T09:00:00Z");
    const { app, crashLoopId } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: { username: "achtung", password: "pw" } } },
      silences: { now: time.now },
    });

    const response = await silence(app, crashLoopId, 4 * hour);

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      id: crashLoopId,
      silencedUntil: "2026-10-13T13:00:00.000Z",
    });
    const created = stub.requests.find((request) => request.method === "POST");
    expect(created?.authorization).toBe(`Basic ${Buffer.from("achtung:pw").toString("base64")}`);
    expect(created?.body).toEqual({
      matchers: Object.entries(crashLoop.labels)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([name, value]) => ({ name, value, isRegex: false, isEqual: true })),
      startsAt: "2026-10-13T09:00:00.000Z",
      endsAt: "2026-10-13T13:00:00.000Z",
      createdBy: "Achtung",
      comment: "Silenced from Achtung: lab #ops, KubePodCrashLooping",
    });
  });

  it("shows the silence on every route, and not on other alerts", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock("2026-10-13T09:00:00Z");
    const { app, crashLoopId } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: time.now },
    });
    await silence(app, crashLoopId, hour);

    const until = (body: { occurrences: { title: string; silencedUntil: string | null }[] }) =>
      Object.fromEntries(body.occurrences.map((o) => [o.title, o.silencedUntil]));
    const expected = { KubePodCrashLooping: "2026-10-13T10:00:00.000Z", TargetDown: null };
    expect(until((await getJson(app, "/api/occurrences")).body)).toEqual(expected);
    expect(until((await getJson(app, "/api/instances/lab/channels/ops/occurrences")).body)).toEqual(
      expected,
    );
    const detail = (await getJson(app, `/api/occurrences/${crashLoopId}`)).body;
    expect(detail.occurrence.silencedUntil).toBe("2026-10-13T10:00:00.000Z");
  });

  it("still covers the alert when it fires again", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock("2026-10-13T09:00:00Z");
    const { app, services, crashLoopId } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: time.now },
    });
    await silence(app, crashLoopId, hour);

    const refire = { ...crashLoop, startsAt: new Date("2026-10-13T09:05:00Z") };
    await deliver(services, [refire], "2026-10-13T09:05:00Z", "ops", "lab");

    const { body } = await getJson(app, `/api/occurrences/${crashLoopId}`);
    expect(body.otherOccurrences).toEqual([
      expect.objectContaining({ silencedUntil: "2026-10-13T10:00:00.000Z" }),
    ]);
  });

  it("stops showing a silence once it has ended", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock("2026-10-13T09:00:00Z");
    const { app, crashLoopId } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: time.now },
    });
    await silence(app, crashLoopId, hour);

    time.advance(hour);

    const { body } = await getJson(app, `/api/occurrences/${crashLoopId}`);
    expect(body.occurrence.silencedUntil).toBeNull();
  });

  it("shows a silence made elsewhere, e.g. in Alertmanager's UI", async () => {
    const stub = await startAlertmanagerStub();
    stub.silences.push({
      id: "from-the-ui",
      status: { state: "active" },
      matchers: [{ name: "namespace", value: "example-.*", isRegex: true }],
      startsAt: "2026-10-13T08:00:00Z",
      endsAt: "2026-10-13T20:00:00Z",
      createdBy: "someone",
      comment: "maintenance",
    });
    const { app, crashLoopId } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: clock("2026-10-13T09:00:00Z").now },
    });

    const { body } = await getJson(app, `/api/occurrences/${crashLoopId}`);

    expect(body.occurrence.silencedUntil).toBe("2026-10-13T20:00:00.000Z");
  });

  it("asks each Alertmanager at most once per 30 seconds", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock("2026-10-13T09:00:00Z");
    const { app } = await appWithAlert({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      silences: { now: time.now },
    });
    const reads = () => stub.requests.filter((request) => request.method === "GET").length;
    expect(reads()).toBe(1);

    await getJson(app, "/api/occurrences");
    await getJson(app, "/api/instances/lab/channels/ops/occurrences");
    expect(reads()).toBe(1);

    time.advance(30);
    await getJson(app, "/api/occurrences");
    expect(reads()).toBe(2);
  });
});
