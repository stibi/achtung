import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, stubAlert, unreachableUrl } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson, targetDown } from "../api.ts";
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
const labAlerts = "/api/alertmanagers/lab/alerts";

async function labApp(url: string, time = clock(at10)) {
  return appWithDatabase({ alertmanagers: { lab: { url, basicAuth: null } }, ...time.options });
}

describe("GET /api/alertmanagers/{instance}/alerts", () => {
  it("lists the alerts the tile counts, by severity, then the newest start first", async () => {
    const stub = await startAlertmanagerStub();
    stub.alerts.push(
      stubAlert("w", { alertname: "Watchdog", severity: "none" }),
      stubAlert("i", { alertname: "InfoInhibitor", severity: "none" }, { state: "suppressed" }),
      stubAlert("b", { alertname: "DiskFilling", severity: "warning" }),
      stubAlert("c", { alertname: "NoSeverity" }, { state: "unprocessed" }),
      stubAlert(
        "a",
        { alertname: "TargetDown", severity: "critical" },
        { startsAt: "2026-10-13T09:30:00Z" },
      ),
      stubAlert(
        "d",
        { alertname: "Muted", severity: "critical" },
        { state: "suppressed", silencedBy: ["s1"], inhibitedBy: ["a"] },
      ),
      stubAlert(
        "e",
        { alertname: "Inhibited", severity: "info" },
        { state: "suppressed", inhibitedBy: ["a"] },
      ),
      stubAlert("f", { alertname: "TimeMuted", severity: "critical" }, { state: "suppressed" }),
    );
    const { app } = await labApp(stub.url);

    const { status, body } = await getJson(app, labAlerts);
    const tile = (await getJson(app, "/api/home")).body.alertmanagers[0];

    expect(status).toBe(200);
    expect(body).toMatchObject({
      instance: "lab",
      reachable: true,
      error: null,
      checkedAt: "2026-10-13T10:00:00.000Z",
    });
    expect(
      body.alerts.map((alert: { title: string; state: string }) => [alert.title, alert.state]),
    ).toEqual([
      ["TargetDown", "active"],
      ["Muted", "silenced"],
      ["DiskFilling", "active"],
      ["Inhibited", "inhibited"],
      ["NoSeverity", "active"],
    ]);
    const inState = (state: string) =>
      body.alerts.filter((alert: { state: string }) => alert.state === state).length;
    expect(tile.open.total).toBe(3);
    expect([inState("active"), inState("silenced"), inState("inhibited")]).toEqual([
      tile.open.total,
      tile.silenced,
      tile.inhibited,
    ]);
    expect(alertReads(stub)).toBe(1);
  });

  it("returns each alert with what Alertmanager reported of it", async () => {
    const stub = await startAlertmanagerStub();
    stub.alerts.push({
      ...stubAlert("a", { alertname: "DiskFilling", severity: "warning" }),
      annotations: { description: "The disk fills up", runbook_url: "https://runbooks.example" },
    });
    const { app } = await labApp(stub.url);

    const { body } = await getJson(app, labAlerts);

    expect(body.alerts).toEqual([
      {
        fingerprint: "a",
        title: "DiskFilling",
        severity: "warning",
        summary: "The disk fills up",
        startsAt: "2026-10-13T09:00:00.000Z",
        labels: { alertname: "DiskFilling", severity: "warning" },
        annotations: { description: "The disk fills up", runbook_url: "https://runbooks.example" },
        state: "active",
        silencedUntil: null,
        occurrenceId: null,
      },
    ]);
  });

  it("says until when a silenced alert is silenced", async () => {
    const stub = await startAlertmanagerStub();
    stub.silences.push({
      id: "s1",
      status: { state: "active" },
      matchers: [{ name: "alertname", value: "Muted", isRegex: false, isEqual: true }],
      startsAt: "2026-10-13T09:00:00Z",
      endsAt: "2026-10-13T14:00:00Z",
      createdBy: "someone",
      comment: "maintenance",
    });
    stub.alerts.push(
      stubAlert("a", { alertname: "Muted" }, { state: "suppressed", silencedBy: ["s1"] }),
      stubAlert("b", { alertname: "Unknown" }, { state: "suppressed", silencedBy: ["gone"] }),
    );
    const { app } = await labApp(stub.url);

    const { body } = await getJson(app, labAlerts);

    expect(
      body.alerts.map((alert: { title: string; silencedUntil: string | null }) => [
        alert.title,
        alert.silencedUntil,
      ]),
    ).toEqual([
      ["Muted", "2026-10-13T14:00:00.000Z"],
      ["Unknown", null],
    ]);
  });

  it("doesn't wait for another Alertmanager's silences", async () => {
    const lab = await startAlertmanagerStub();
    const slow = await startAlertmanagerStub();
    lab.alerts.push(
      stubAlert("a", { alertname: "Muted" }, { state: "suppressed", silencedBy: ["s1"] }),
    );
    const held = slow.holdNextRead();
    const { app } = await appWithDatabase({
      alertmanagers: {
        lab: { url: lab.url, basicAuth: null },
        slow: { url: slow.url, basicAuth: null },
      },
      ...clock(at10).options,
    });

    const listed = getJson(app, labAlerts);
    const first = await Promise.race([
      listed.then(() => "listed"),
      held.arrived.then(() => "waited"),
    ]);
    held.release();

    expect(first).toBe("listed");
    expect((await listed).body.alerts).toMatchObject([{ fingerprint: "a", state: "silenced" }]);
  });

  it("links each alert to its occurrence of the same firing on the instance", async () => {
    const stub = await startAlertmanagerStub();
    stub.alerts.push(
      // The same firing as in Achtung.
      stubAlert(crashLoop.sourceKey, crashLoop.labels, { startsAt: "2026-10-13T08:15:30.123Z" }),
      // Fired again after Achtung's occurrence: a new firing, with no occurrence yet.
      stubAlert(targetDown.sourceKey, targetDown.labels, { startsAt: "2026-10-13T09:40:00Z" }),
      // Fires in Achtung, but from another instance.
      stubAlert("elsewhere", { alertname: "Elsewhere" }, { startsAt: "2026-10-13T09:00:00Z" }),
    );
    const { app, services } = await labApp(stub.url);
    await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z");
    const elsewhere = {
      ...crashLoop,
      sourceKey: "elsewhere",
      startsAt: new Date("2026-10-13T09:00:00Z"),
    };
    await deliver(services, [elsewhere], "2026-10-13T09:00:00Z", "example-prod", "other");
    const { body: feed } = await getJson(app, "/api/occurrences");
    const idOf = (sourceKey: string) =>
      feed.occurrences.find(
        (occurrence: { instance: string; sourceKey: string }) =>
          occurrence.instance === "lab" && occurrence.sourceKey === sourceKey,
      ).id;

    const { body } = await getJson(app, labAlerts);

    expect(
      Object.fromEntries(
        body.alerts.map((alert: { fingerprint: string; occurrenceId: number | null }) => [
          alert.fingerprint,
          alert.occurrenceId,
        ]),
      ),
    ).toEqual({
      [crashLoop.sourceKey]: idOf(crashLoop.sourceKey),
      [targetDown.sourceKey]: null,
      elsewhere: null,
    });
  });

  it("keeps the last alerts it read while the Alertmanager is down", async () => {
    const stub = await startAlertmanagerStub();
    stub.alerts.push(stubAlert("a", { alertname: "TargetDown", severity: "critical" }));
    const time = clock(at10);
    const { app } = await labApp(stub.url, time);
    await getJson(app, labAlerts);

    stub.fail(503, "down for maintenance");
    time.advance(60);
    const { body } = await getJson(app, labAlerts);

    expect(body).toMatchObject({
      instance: "lab",
      reachable: false,
      error: "Alertmanager answered 503",
      checkedAt: "2026-10-13T10:00:00.000Z",
      alerts: [{ fingerprint: "a", state: "active" }],
    });
  });

  it("lists nothing for an Alertmanager it never read", async () => {
    const { app } = await labApp(await unreachableUrl());

    const { status, body } = await getJson(app, labAlerts);

    expect(status).toBe(200);
    expect(body).toEqual({
      instance: "lab",
      reachable: false,
      error: expect.stringContaining("unreachable"),
      checkedAt: null,
      alerts: [],
    });
  });

  it("is a 404 for an instance without an Alertmanager", async () => {
    const stub = await startAlertmanagerStub();
    const { app } = await labApp(stub.url);

    const { status, body } = await getJson(app, "/api/alertmanagers/prod/alerts");

    expect(status).toBe(404);
    expect(body).toEqual({ error: "Alertmanager not found" });
    expect(alertReads(stub)).toBe(0);
  });

  it("shares one read per 30 seconds with the home view", async () => {
    const stub = await startAlertmanagerStub();
    const time = clock(at10);
    const { app } = await labApp(stub.url, time);

    await Promise.all([getJson(app, labAlerts), getJson(app, "/api/home")]);
    expect(alertReads(stub)).toBe(1);

    stub.alerts.push(stubAlert("a", { alertname: "TargetDown", severity: "critical" }));
    time.advance(29);
    expect((await getJson(app, labAlerts)).body.alerts).toEqual([]);
    expect(alertReads(stub)).toBe(1);

    time.advance(1);
    const [{ body: home }, { body: list }] = await Promise.all([
      getJson(app, "/api/home"),
      getJson(app, labAlerts),
    ]);
    expect(alertReads(stub)).toBe(2);
    expect(home.alertmanagers[0].open.total).toBe(1);
    expect(list).toMatchObject({
      checkedAt: "2026-10-13T10:00:30.000Z",
      alerts: [{ fingerprint: "a" }],
    });
  });
});
