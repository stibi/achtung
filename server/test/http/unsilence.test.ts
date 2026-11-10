import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { type AlertmanagerStub, startAlertmanagerStub } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";

// Changing and ending an alert's own silence (ADR 0015).

const hour = 3600;

async function silencedLab() {
  const stub = await startAlertmanagerStub();
  const time = new Date("2026-10-13T09:00:00Z");
  const { app, services } = await appWithDatabase({
    alertmanagers: { lab: { url: stub.url, basicAuth: null } },
    silences: { now: () => time },
  });
  await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");
  const { body } = await getJson(app, "/api/occurrences");
  const id: number = body.occurrences[0].id;
  return { stub, app, id };
}

const silence = (app: FastifyInstance, id: number, durationSeconds: number) =>
  app.inject({ method: "POST", url: `/api/occurrences/${id}/silence`, body: { durationSeconds } });

const unsilence = (app: FastifyInstance, id: number) =>
  app.inject({ method: "DELETE", url: `/api/occurrences/${id}/silence` });

const states = (stub: AlertmanagerStub) =>
  Object.fromEntries(stub.silences.map((silence) => [silence.id, silence.status.state]));

/** A silence made elsewhere that mutes every alert in the namespace, not only this one. */
function broadSilence(stub: AlertmanagerStub, endsAt = "2026-10-13T20:00:00Z") {
  stub.silences.push({
    id: "maintenance",
    status: { state: "active" },
    matchers: [{ name: "namespace", value: crashLoop.labels["namespace"] ?? "", isRegex: false }],
    startsAt: "2026-10-13T08:00:00Z",
    endsAt,
    createdBy: "someone",
    comment: "maintenance",
  });
}

describe("POST /api/occurrences/{id}/silence on a silenced alert", () => {
  it("changes its silence to end then, also sooner, instead of adding one", async () => {
    const { stub, app, id } = await silencedLab();
    await silence(app, id, 4 * hour);

    const response = await silence(app, id, hour);

    expect(response.statusCode).toBe(200);
    expect(response.json().silencedUntil).toBe("2026-10-13T10:00:00.000Z");
    expect(stub.silences).toEqual([
      expect.objectContaining({ id: "silence-1", endsAt: "2026-10-13T10:00:00.000Z" }),
    ]);
    expect(stub.requests.at(-2)?.body).toMatchObject({ id: "silence-1" });
  });

  it("changes one made in Alertmanager in place, keeping its start and matcher order", async () => {
    const { stub, app, id } = await silencedLab();
    const matchers = Object.entries(crashLoop.labels)
      .map(([name, value]) => ({ name, value, isRegex: false, isEqual: true }))
      .toReversed();
    stub.silences.push({
      id: "from-the-ui",
      status: { state: "active" },
      matchers,
      startsAt: "2026-10-13T08:00:00.000Z",
      endsAt: "2026-10-14T08:00:00.000Z",
      createdBy: "someone",
      comment: "flapping",
    });

    const response = await silence(app, id, hour);

    expect(response.json().silencedUntil).toBe("2026-10-13T10:00:00.000Z");
    expect(stub.silences).toEqual([
      expect.objectContaining({
        id: "from-the-ui",
        status: { state: "active" },
        matchers,
        startsAt: "2026-10-13T08:00:00.000Z",
        endsAt: "2026-10-13T10:00:00.000Z",
      }),
    ]);
  });

  it("ends any further silence of its own, which would outlast the new end", async () => {
    const { stub, app, id } = await silencedLab();
    await silence(app, id, 4 * hour);
    const [first] = stub.silences;
    stub.silences.push({ ...structuredClone(first!), id: "twin", endsAt: "2026-10-13T11:00:00Z" });

    const response = await silence(app, id, hour);

    expect(response.json().silencedUntil).toBe("2026-10-13T10:00:00.000Z");
    expect(states(stub)).toEqual({ "silence-1": "active", twin: "expired" });
  });
});

describe("DELETE /api/occurrences/{id}/silence", () => {
  it("ends the alert's own silences now", async () => {
    const { stub, app, id } = await silencedLab();
    await silence(app, id, hour);

    const response = await unsilence(app, id);

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ id, silencedUntil: null });
    expect(states(stub)).toEqual({ "silence-1": "expired" });
    expect(stub.requests.filter((request) => request.method === "DELETE")).toEqual([
      expect.objectContaining({ path: "/api/v2/silence/silence-1" }),
    ]);
    expect((await getJson(app, `/api/occurrences/${id}`)).body.occurrence.silencedUntil).toBeNull();
  });

  it("reads the silences fresh, not from the last 30 seconds", async () => {
    const { stub, app, id } = await silencedLab();
    await getJson(app, "/api/occurrences");
    stub.silences.push({
      id: "just-made",
      status: { state: "active" },
      matchers: Object.entries(crashLoop.labels).map(([name, value]) => ({
        name,
        value,
        isRegex: false,
        isEqual: true,
      })),
      startsAt: "2026-10-13T08:55:00.000Z",
      endsAt: "2026-10-13T12:00:00.000Z",
      createdBy: "someone",
      comment: "",
    });

    const response = await unsilence(app, id);

    expect(response.statusCode).toBe(200);
    expect(states(stub)).toEqual({ "just-made": "expired" });
  });

  it("leaves a broader silence alone, and says it still mutes the alert", async () => {
    const { stub, app, id } = await silencedLab();
    await silence(app, id, hour);
    broadSilence(stub);

    const response = await unsilence(app, id);

    expect(response.statusCode).toBe(200);
    expect(response.json().silencedUntil).toBe("2026-10-13T20:00:00.000Z");
    expect(states(stub)).toEqual({ "silence-1": "expired", maintenance: "active" });
  });

  it("answers 409 when only a broader silence mutes the alert, and ends nothing", async () => {
    const { stub, app, id } = await silencedLab();
    broadSilence(stub);

    const response = await unsilence(app, id);

    expect(response.statusCode).toBe(409);
    expect(response.json().error).toContain("also mutes other alerts");
    expect(states(stub)).toEqual({ maintenance: "active" });
    expect(stub.requests.filter((request) => request.method === "DELETE")).toEqual([]);
  });

  it("is no error for an alert without a silence", async () => {
    const { app, id } = await silencedLab();

    const response = await unsilence(app, id);

    expect(response.statusCode).toBe(200);
    expect(response.json().silencedUntil).toBeNull();
  });

  it("answers 502 when Alertmanager refuses", async () => {
    const { stub, app, id } = await silencedLab();
    await silence(app, id, hour);
    stub.fail(500, "boom");

    const response = await unsilence(app, id);

    expect(response.statusCode).toBe(502);
    expect(response.json().error).toContain("Alertmanager answered 500");
  });

  it("answers 404 for an occurrence it doesn't have, and 409 without an Alertmanager", async () => {
    const { app } = await silencedLab();
    expect((await unsilence(app, 999)).statusCode).toBe(404);

    const { app: bare, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");
    const { body } = await getJson(bare, "/api/occurrences");
    const response = await unsilence(bare, body.occurrences[0].id);
    expect(response.statusCode).toBe(409);
  });
});
