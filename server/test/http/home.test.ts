import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, stubAlert, unreachableUrl } from "../alertmanager-stub.ts";
import { getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";

/** One clock for the app's Alertmanager reads and its services. */
function clock(start: string) {
  let current = new Date(start);
  const now = () => current;
  return {
    options: { silences: { now }, alerts: { now }, now },
    advance: (seconds: number) => {
      current = new Date(current.getTime() + seconds * 1000);
    },
  };
}

const at10 = "2026-10-13T10:00:00Z";
const alertReads = (stub: { requests: { method: string; path: string }[] }) =>
  stub.requests.filter((request) => request.path === "/api/v2/alerts").length;

describe("GET /api/home: Alertmanagers", () => {
  it("shows every configured Alertmanager by name, with what it has open", async () => {
    const stub = await startAlertmanagerStub();
    const quiet = await startAlertmanagerStub();
    stub.alerts.push(
      stubAlert("w", { alertname: "Watchdog", severity: "none" }),
      stubAlert("i", { alertname: "InfoInhibitor", severity: "none" }),
      stubAlert("a", { alertname: "TargetDown", severity: "critical" }),
      stubAlert("b", { alertname: "DiskFilling", severity: "warning" }),
      stubAlert("c", { alertname: "NoSeverity" }, { state: "unprocessed" }),
      stubAlert(
        "d",
        { alertname: "Muted", severity: "critical" },
        {
          state: "suppressed",
          silencedBy: ["s1"],
          inhibitedBy: ["a"],
        },
      ),
      stubAlert(
        "e",
        { alertname: "Inhibited", severity: "info" },
        {
          state: "suppressed",
          inhibitedBy: ["a"],
        },
      ),
    );
    const { app } = await appWithDatabase({
      alertmanagers: {
        zulu: { url: quiet.url, basicAuth: null },
        lab: { url: stub.url, basicAuth: null },
      },
      ...clock(at10).options,
    });

    const { status, body } = await getJson(app, "/api/home");

    expect(status).toBe(200);
    expect(body.alertmanagers).toEqual([
      {
        instance: "lab",
        reachable: true,
        error: null,
        checkedAt: "2026-10-13T10:00:00.000Z",
        open: { total: 3, critical: 1, warning: 1, info: 0, other: 1 },
        silenced: 1,
        inhibited: 1,
        watchdog: "firing",
        delivery: { missingInAchtung: [], staleInAchtung: [] },
        irm: null,
      },
      {
        instance: "zulu",
        reachable: true,
        error: null,
        checkedAt: "2026-10-13T10:00:00.000Z",
        open: { total: 0, critical: 0, warning: 0, info: 0, other: 0 },
        silenced: 0,
        inhibited: 0,
        watchdog: "absent",
        delivery: { missingInAchtung: [], staleInAchtung: [] },
        irm: null,
      },
    ]);
  });

  it("shows an unreachable Alertmanager without its address", async () => {
    const url = await unreachableUrl();
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url, basicAuth: { username: "achtung", password: "secret" } } },
    });

    const { status, body } = await getJson(app, "/api/home");

    expect(status).toBe(200);
    expect(body.alertmanagers).toEqual([
      {
        instance: "lab",
        reachable: false,
        error: expect.stringContaining("unreachable"),
        checkedAt: null,
        open: null,
        silenced: null,
        inhibited: null,
        watchdog: null,
        delivery: null,
        irm: null,
      },
    ]);
    const error = body.alertmanagers[0].error as string;
    expect(error).not.toContain(new URL(url).hostname);
    expect(error).not.toContain("secret");
  });

  it("keeps the last alerts it read while the Alertmanager is down", async () => {
    const stub = await startAlertmanagerStub();
    stub.alerts.push(stubAlert("a", { alertname: "TargetDown", severity: "critical" }));
    const time = clock(at10);
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      ...time.options,
    });
    await getJson(app, "/api/home");

    stub.fail(503, "down for maintenance");
    time.advance(60);
    const { body } = await getJson(app, "/api/home");

    expect(body.alertmanagers[0]).toMatchObject({
      reachable: false,
      // The body can be a proxy's error page naming hosts; only the log gets it.
      error: "Alertmanager answered 503",
      checkedAt: "2026-10-13T10:00:00.000Z",
      open: { total: 1, critical: 1 },
      watchdog: "absent",
      delivery: { missingInAchtung: [], staleInAchtung: [] },
    });
  });

  it("asks each Alertmanager for its alerts at most once per 30 seconds", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock(at10);
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
      ...time.options,
    });

    await Promise.all([getJson(app, "/api/home"), getJson(app, "/api/home")]);
    expect(alertReads(stub)).toBe(1);

    stub.alerts.push(stubAlert("a", { alertname: "TargetDown", severity: "critical" }));
    time.advance(29);
    expect((await getJson(app, "/api/home")).body.alertmanagers[0].open.total).toBe(0);
    expect(alertReads(stub)).toBe(1);

    time.advance(1);
    const { body } = await getJson(app, "/api/home");
    expect(alertReads(stub)).toBe(2);
    expect(body.alertmanagers[0]).toMatchObject({
      checkedAt: "2026-10-13T10:00:30.000Z",
      open: { total: 1 },
    });
  });

  it("lists nothing when no Alertmanager is configured", async () => {
    const { app } = await appWithDatabase();

    expect((await getJson(app, "/api/home")).body).toEqual({
      alertmanagers: [],
      silences: [],
      noisiest: [],
      longestFiring: [],
    });
  });
});

describe("GET /api/home: silences", () => {
  it("lists the silences active now on every Alertmanager, the soonest to end first", async () => {
    const lab = await startAlertmanagerStub();
    const prod = await startAlertmanagerStub();
    const matchers = [{ name: "namespace", value: "example-.*", isRegex: true, isEqual: false }];
    const silence = (id: string, startsAt: string, endsAt: string) => ({
      id,
      status: { state: "active" as const },
      matchers,
      startsAt,
      endsAt,
      createdBy: "someone",
      comment: `maintenance ${id}`,
    });
    lab.silences.push(
      silence("late", "2026-10-13T08:00:00Z", "2026-10-14T08:00:00Z"),
      silence("pending", "2026-10-13T11:00:00Z", "2026-10-13T12:00:00Z"),
      {
        ...silence("expired", "2026-10-13T08:00:00Z", "2026-10-13T09:00:00Z"),
        status: { state: "expired" },
      },
    );
    prod.silences.push(silence("soon", "2026-10-13T09:00:00Z", "2026-10-13T10:30:00Z"));
    const { app } = await appWithDatabase({
      alertmanagers: {
        lab: { url: lab.url, basicAuth: null },
        prod: { url: prod.url, basicAuth: null },
      },
      ...clock(at10).options,
    });

    const { body } = await getJson(app, "/api/home");

    expect(body.silences).toEqual([
      {
        instance: "prod",
        id: "soon",
        startsAt: "2026-10-13T09:00:00.000Z",
        endsAt: "2026-10-13T10:30:00.000Z",
        createdBy: "someone",
        comment: "maintenance soon",
        matchers,
      },
      expect.objectContaining({ instance: "lab", id: "late" }),
    ]);
  });
});
