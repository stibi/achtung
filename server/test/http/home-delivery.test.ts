import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, stubAlert } from "../alertmanager-stub.ts";
import { crashLoop, crashLoopResolved, deliver, getJson, targetDown } from "../api.ts";
import { appWithDatabase } from "../app.ts";
import { loadFixture } from "../fixtures.ts";

const at10 = () => new Date("2026-10-13T10:00:00Z");
const atTen = { silences: { now: at10 }, alerts: { now: at10 }, now: at10 };

const labels = (alertname: string) => ({ alertname, severity: "warning" });

describe("GET /api/home: alerts missing in Achtung", () => {
  it("lists what Alertmanager sends Achtung's receivers, but doesn't fire in Achtung", async () => {
    const lab = await startAlertmanagerStub();
    lab.alerts.push(
      // Fires in Achtung.
      stubAlert(crashLoop.sourceKey, crashLoop.labels, { startsAt: "2026-10-13T08:15:30.123Z" }),
      // Resolved in Achtung, still active in Alertmanager.
      stubAlert(targetDown.sourceKey, targetDown.labels, { startsAt: "2026-10-13T08:20:00Z" }),
      stubAlert("lost", labels("Lost"), { startsAt: "2026-10-13T09:49:59Z" }),
      // Fires in Achtung, but from another instance.
      stubAlert("elsewhere", labels("Elsewhere"), { startsAt: "2026-10-13T09:00:00Z" }),
      // Within the grace: its notification may still be on its way.
      stubAlert("young", labels("Young"), { startsAt: "2026-10-13T09:50:00Z" }),
      // Routed only to receivers that don't deliver to Achtung.
      stubAlert("paged", labels("Paged"), { receivers: ["pager"] }),
      stubAlert("silenced", labels("Silenced"), { state: "suppressed", silencedBy: ["s1"] }),
    );
    const { app, services } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      ...atTen,
    });
    await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z");
    const resolved = {
      ...targetDown,
      status: "resolved",
      endsAt: new Date("2026-10-13T08:40:00Z"),
    };
    await deliver(services, [resolved as typeof targetDown], "2026-10-13T08:40:00Z");
    const elsewhere = { ...crashLoop, sourceKey: "elsewhere" };
    await deliver(services, [elsewhere], "2026-10-13T09:00:00Z", "example-prod", "other");

    const { body } = await getJson(app, "/api/home");

    expect(body.alertmanagers[0].delivery.missingInAchtung).toEqual([
      {
        fingerprint: targetDown.sourceKey,
        title: "TargetDown",
        severity: "critical",
        startsAt: "2026-10-13T08:20:00.000Z",
      },
      {
        fingerprint: "elsewhere",
        title: "Elsewhere",
        severity: "warning",
        startsAt: "2026-10-13T09:00:00.000Z",
      },
      {
        fingerprint: "lost",
        title: "Lost",
        severity: "warning",
        startsAt: "2026-10-13T09:49:59.000Z",
      },
    ]);
  });

  it("doesn't expect an alert that resolved in Achtung after Alertmanager was read", async () => {
    const lab = await startAlertmanagerStub();
    lab.alerts.push(
      stubAlert(crashLoop.sourceKey, crashLoop.labels, { startsAt: "2026-10-13T08:15:30.123Z" }),
    );
    let now = new Date("2026-10-13T10:00:00Z");
    const clock = () => now;
    const { app, services } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      silences: { now: clock },
      alerts: { now: clock },
      now: clock,
    });
    await deliver(services, [crashLoop], "2026-10-13T09:00:00Z");
    await getJson(app, "/api/home");

    await deliver(services, [crashLoopResolved], "2026-10-13T10:00:10Z");
    now = new Date("2026-10-13T10:00:20Z");
    const { body } = await getJson(app, "/api/home");

    expect(body.alertmanagers[0]).toMatchObject({
      checkedAt: "2026-10-13T10:00:00.000Z",
      delivery: { missingInAchtung: [], staleInAchtung: [] },
    });
  });

  it("learns the receivers from the webhooks Alertmanager sends", async () => {
    const lab = await startAlertmanagerStub();
    const hourAgo = new Date(Date.now() - 3600_000).toISOString();
    lab.alerts.push(
      stubAlert("lost", labels("Lost"), { receivers: ["achtung-example-prod"], startsAt: hourAgo }),
      stubAlert("paged", labels("Paged"), { receivers: ["pager"], startsAt: hourAgo }),
    );
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
    });
    const missing = async () =>
      (await getJson(app, "/api/home")).body.alertmanagers[0].delivery.missingInAchtung;
    expect(await missing()).toEqual([]);

    // The fixture's receiver is achtung-example-prod.
    const ingest = await app.inject({
      method: "POST",
      url: "/ingest/alertmanager/lab/ops",
      body: loadFixture("alertmanager", "firing") as object,
    });
    expect(ingest.statusCode).toBe(200);

    expect(await missing()).toEqual([expect.objectContaining({ fingerprint: "lost" })]);
  });
});

describe("GET /api/home: occurrences stale in Achtung", () => {
  it("lists what fires in Achtung but is gone from its Alertmanager", async () => {
    const lab = await startAlertmanagerStub();
    const other = await startAlertmanagerStub();
    lab.alerts.push(
      stubAlert(crashLoop.sourceKey, crashLoop.labels, {
        state: "suppressed",
        silencedBy: ["s1"],
        receivers: ["pager"],
        startsAt: "2026-10-13T08:15:30.123Z",
      }),
    );
    // Another instance's Alertmanager has it; that doesn't make it current on lab.
    other.alerts.push(stubAlert(targetDown.sourceKey, targetDown.labels));
    const { app, services } = await appWithDatabase({
      alertmanagers: {
        lab: { url: lab.url, basicAuth: null },
        other: { url: other.url, basicAuth: null },
      },
      ...atTen,
    });
    await deliver(services, [crashLoop, targetDown], "2026-10-13T09:40:00Z");
    // Repeated notifications keep it current until the grace after the last one.
    const recent = { ...crashLoop, sourceKey: "recent" };
    await deliver(services, [recent], "2026-10-13T09:30:00Z");
    await deliver(services, [recent], "2026-10-13T09:50:00Z");

    const { body } = await getJson(app, "/api/home");

    const [labTile, otherTile] = body.alertmanagers;
    expect(labTile.delivery.staleInAchtung).toEqual([
      expect.objectContaining({
        instance: "lab",
        sourceKey: targetDown.sourceKey,
        status: "firing",
        lastReceivedAt: "2026-10-13T09:40:00.000Z",
        silencedUntil: null,
      }),
    ]);
    expect(otherTile.delivery).toEqual({ missingInAchtung: [], staleInAchtung: [] });
  });

  it("is reported, not resolved", async () => {
    const lab = await startAlertmanagerStub();
    const { app, services } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      ...atTen,
    });
    await deliver(services, [crashLoop], "2026-10-13T09:00:00Z");

    await getJson(app, "/api/home");

    const { body } = await getJson(app, "/api/occurrences?status=firing");
    expect(body.occurrences).toEqual([expect.objectContaining({ sourceKey: crashLoop.sourceKey })]);
  });
});
