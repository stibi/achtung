import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, stubAlert } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";

// The ignored alert names (ADR 0011) as the Home views apply them.

const at10 = () => new Date("2026-10-13T10:00:00Z");
const atTen = { silences: { now: at10 }, alerts: { now: at10 }, now: at10 };
const alertReads = (stub: { requests: { method: string; path: string }[] }) =>
  stub.requests.filter((request) => request.path === "/api/v2/alerts").length;

async function ignore(app: FastifyInstance, names: string[]) {
  const response = await app.inject({
    method: "PUT",
    url: "/api/settings/ignored-alerts",
    body: { names },
  });
  expect(response.statusCode).toBe(200);
}

const tile = async (app: FastifyInstance) =>
  (await getJson(app, "/api/home")).body.alertmanagers[0];
const listedTitles = async (app: FastifyInstance) =>
  (await getJson(app, "/api/alertmanagers/lab/alerts")).body.alerts.map(
    (alert: { title: string }) => alert.title,
  );

describe("ignored alert names on Home", () => {
  it("apply to the next request, within the same cached Alertmanager read", async () => {
    const lab = await startAlertmanagerStub();
    lab.alerts.push(
      stubAlert("w", { alertname: "Watchdog", severity: "none" }),
      stubAlert("h", { alertname: "grafana-irm-heartbeat", severity: "critical" }),
      stubAlert("d", { alertname: "DiskFilling", severity: "warning" }),
      stubAlert("n", { alertname: "Noisy", severity: "warning" }),
      stubAlert(
        "s",
        { alertname: "Noisy", severity: "info" },
        { state: "suppressed", silencedBy: ["s1"] },
      ),
    );
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      ...atTen,
    });
    expect(await tile(app)).toMatchObject({
      open: { total: 2, critical: 0, warning: 2, info: 0, other: 0 },
      silenced: 1,
    });
    expect(await listedTitles(app)).toEqual(["DiskFilling", "Noisy", "Noisy"]);

    await ignore(app, ["Watchdog", "grafana-irm-heartbeat", "Noisy"]);

    expect(await tile(app)).toMatchObject({
      open: { total: 1, critical: 0, warning: 1, info: 0, other: 0 },
      silenced: 0,
      inhibited: 0,
    });
    expect(await listedTitles(app)).toEqual(["DiskFilling"]);
    expect(alertReads(lab)).toBe(1);
  });

  it("count Watchdog as other once it's no longer ignored, and its heart fires either way", async () => {
    const lab = await startAlertmanagerStub();
    lab.alerts.push(stubAlert("w", { alertname: "Watchdog", severity: "none" }));
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      ...atTen,
    });
    expect(await tile(app)).toMatchObject({
      open: { total: 0, other: 0 },
      watchdog: "firing",
    });

    await ignore(app, ["InfoInhibitor"]);

    expect(await tile(app)).toMatchObject({
      open: { total: 1, critical: 0, warning: 0, info: 0, other: 1 },
      watchdog: "firing",
    });
    expect(await listedTitles(app)).toEqual(["Watchdog"]);
  });

  it("keep an ignored alert out of the delivery check, missing or stale", async () => {
    const lab = await startAlertmanagerStub();
    lab.alerts.push(
      // Routed to Achtung's receiver, but never delivered: missing, unless ignored, as the
      // heartbeat is from the start (the seed).
      stubAlert("h", { alertname: "grafana-irm-heartbeat", severity: "none" }),
      stubAlert("lost", { alertname: "Lost", severity: "warning" }),
    );
    const { app, services } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      ...atTen,
    });
    // Fires in Achtung, gone from Alertmanager: stale, unless ignored.
    await deliver(services, [crashLoop], "2026-10-13T09:00:00Z");
    const before = (await tile(app)).delivery;
    expect(before.missingInAchtung.map((alert: { title: string }) => alert.title)).toEqual([
      "Lost",
    ]);
    expect(before.staleInAchtung).toEqual([
      expect.objectContaining({ sourceKey: crashLoop.sourceKey }),
    ]);

    await ignore(app, ["grafana-irm-heartbeat", crashLoop.labels["alertname"] as string, "Lost"]);

    expect((await tile(app)).delivery).toEqual({ missingInAchtung: [], staleInAchtung: [] });
    expect(alertReads(lab)).toBe(1);
  });
});
