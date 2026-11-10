import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { type AlertmanagerStub, startAlertmanagerStub, stubAlert } from "../alertmanager-stub.ts";
import { getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";

// Silencing several of an Alertmanager's alerts from its tile's detail (ADR 0016).

const hour = 3600;
const at9 = () => new Date("2026-10-13T09:00:00Z");

async function labWithAlerts() {
  const stub = await startAlertmanagerStub();
  stub.alerts.push(
    stubAlert("fp-disk", { alertname: "DiskFull", severity: "critical", pod: "db-0" }),
    stubAlert("fp-cpu", { alertname: "CPUThrottling", severity: "warning" }),
    stubAlert("fp-mem", { alertname: "MemoryHigh", severity: "warning" }),
  );
  const { app } = await appWithDatabase({
    alertmanagers: { lab: { url: stub.url, basicAuth: null } },
    silences: { now: at9 },
    alerts: { now: at9 },
    now: at9,
  });
  return { stub, app };
}

const silenceAlerts = (app: FastifyInstance, fingerprints: string[], instance = "lab") =>
  app.inject({
    method: "POST",
    url: `/api/alertmanagers/${instance}/silences`,
    body: { fingerprints, durationSeconds: 4 * hour },
  });

const matchersOf = (stub: AlertmanagerStub) =>
  stub.silences
    .filter((silence) => silence.status.state === "active")
    .map((silence) => Object.fromEntries(silence.matchers.map((m) => [m.name, m.value])));

describe("POST /api/alertmanagers/{instance}/silences", () => {
  it("silences each alert asked for with its own exact silence", async () => {
    const { stub, app } = await labWithAlerts();

    const response = await silenceAlerts(app, ["fp-disk", "fp-mem"]);

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      alerts: [
        { fingerprint: "fp-disk", silencedUntil: "2026-10-13T13:00:00.000Z", error: null },
        { fingerprint: "fp-mem", silencedUntil: "2026-10-13T13:00:00.000Z", error: null },
      ],
    });
    expect(matchersOf(stub)).toEqual([
      { alertname: "DiskFull", severity: "critical", pod: "db-0" },
      { alertname: "MemoryHigh", severity: "warning" },
    ]);
    expect(stub.silences[0]).toMatchObject({
      createdBy: "Achtung",
      comment: "Silenced from Achtung: lab, DiskFull",
      endsAt: "2026-10-13T13:00:00.000Z",
    });
    // The silences were read once, fresh, for all of them.
    expect(
      stub.requests.filter((r) => r.path === "/api/v2/silences" && r.method === "GET"),
    ).toHaveLength(1);
  });

  it("shows them as silenced at once in the tile's list", async () => {
    const { stub, app } = await labWithAlerts();
    await getJson(app, "/api/alertmanagers/lab/alerts");

    await silenceAlerts(app, ["fp-cpu"]);
    // Alertmanager suppresses what it has silenced.
    const silenced = stub.alerts[1];
    silenced!.status = { state: "suppressed", silencedBy: ["s"], inhibitedBy: [], mutedBy: ["s"] };

    const { body } = await getJson(app, "/api/alertmanagers/lab/alerts");
    expect(
      body.alerts.find((alert: { fingerprint: string }) => alert.fingerprint === "fp-cpu"),
    ).toMatchObject({ state: "silenced" });
  });

  it("changes an alert's existing silence rather than adding one", async () => {
    const { stub, app } = await labWithAlerts();
    await silenceAlerts(app, ["fp-cpu"]);

    const response = await app.inject({
      method: "POST",
      url: "/api/alertmanagers/lab/silences",
      body: { fingerprints: ["fp-cpu", "fp-cpu"], durationSeconds: hour },
    });

    const result = {
      fingerprint: "fp-cpu",
      silencedUntil: "2026-10-13T10:00:00.000Z",
      error: null,
    };
    expect(response.json().alerts).toEqual([result, result]);

    expect(stub.silences).toEqual([
      expect.objectContaining({ status: { state: "active" }, endsAt: "2026-10-13T10:00:00.000Z" }),
    ]);
  });

  it("reports an alert that is gone from Alertmanager, and silences the rest", async () => {
    const { stub, app } = await labWithAlerts();

    const response = await silenceAlerts(app, ["fp-gone", "fp-cpu"]);

    expect(response.json().alerts).toEqual([
      { fingerprint: "fp-gone", silencedUntil: null, error: "No longer in Alertmanager" },
      { fingerprint: "fp-cpu", silencedUntil: "2026-10-13T13:00:00.000Z", error: null },
    ]);
    expect(matchersOf(stub)).toEqual([{ alertname: "CPUThrottling", severity: "warning" }]);
  });

  it("answers 404 for an instance without an Alertmanager", async () => {
    const { app } = await labWithAlerts();

    expect((await silenceAlerts(app, ["fp-cpu"], "elsewhere")).statusCode).toBe(404);
  });

  it("answers 502 when Alertmanager can't be read or refuses", async () => {
    const { stub, app } = await labWithAlerts();
    stub.failReads(503, "<html>proxy.internal.example.com</html>");
    const unread = await silenceAlerts(app, ["fp-cpu"]);
    expect(unread.statusCode).toBe(502);
    expect(unread.json().error).toBe("Alertmanager answered 503");

    stub.failReads(null);
    stub.fail(500, "boom");
    const response = await silenceAlerts(app, ["fp-cpu"]);
    expect(response.statusCode).toBe(502);
  });

  it("refuses an empty list", async () => {
    const { app } = await labWithAlerts();

    expect((await silenceAlerts(app, [])).statusCode).toBe(400);
  });
});
