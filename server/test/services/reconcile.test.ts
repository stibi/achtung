import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, stubAlert } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson, targetDown } from "../api.ts";
import { appWithDatabase } from "../app.ts";

// Occurrences that fire in Achtung but are gone from their Alertmanager get resolved
// (ADR 0014).

function clock(start: string) {
  let current = new Date(start);
  return {
    now: () => current,
    at: (time: string) => {
      current = new Date(time);
    },
  };
}

async function labWithCrashLoopOnly() {
  const lab = await startAlertmanagerStub();
  lab.alerts.push(
    stubAlert(crashLoop.sourceKey, crashLoop.labels, {
      startsAt: crashLoop.startsAt.toISOString(),
    }),
  );
  const time = clock("2026-10-13T09:00:00Z");
  const { app, services, reconciler } = await appWithDatabase({
    alertmanagers: { lab: { url: lab.url, basicAuth: null } },
    silences: { now: time.now },
    alerts: { now: time.now },
    now: time.now,
  });
  const occurrence = async (sourceKey: string) => {
    const { body } = await getJson(app, "/api/occurrences");
    const listed = body.occurrences.find(
      (item: { sourceKey: string }) => item.sourceKey === sourceKey,
    );
    const { body: detail } = await getJson(app, `/api/occurrences/${listed.id}`);
    return { ...detail.occurrence, events: detail.events };
  };
  // Reads are cached for 30 seconds (ADR 0010), so runs here are further apart.
  const runAt = async (at: string) => {
    time.at(at);
    return reconciler.run();
  };
  return { lab, app, services, reconciler, occurrence, runAt, time };
}

describe("resolving occurrences gone from their Alertmanager", () => {
  it("resolves one gone for five minutes, and says why in its history", async () => {
    const { services, occurrence, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [crashLoop, targetDown], "2026-10-13T09:00:00Z");

    expect(await runAt("2026-10-13T10:00:00Z")).toEqual({ resolved: [] });
    expect(await runAt("2026-10-13T10:04:00Z")).toEqual({ resolved: [] });
    const { resolved } = await runAt("2026-10-13T10:05:00Z");

    const gone = await occurrence(targetDown.sourceKey);
    expect(resolved).toEqual([gone.id]);
    expect(gone).toMatchObject({
      status: "resolved",
      // The first read without it: the closest Achtung knows to when it ended.
      endsAt: "2026-10-13T10:00:00.000Z",
      lastEventKind: "resolved",
      lastEventAt: "2026-10-13T10:05:00.000Z",
      notificationCount: 1,
    });
    expect(gone.events).toEqual([
      expect.objectContaining({ kind: "fired", cause: null }),
      expect.objectContaining({
        kind: "resolved",
        cause: "vanished",
        recordedAt: "2026-10-13T10:05:00.000Z",
      }),
    ]);
    expect(await occurrence(crashLoop.sourceKey)).toMatchObject({ status: "firing" });
  });

  it("leaves one notified within the delivery grace", async () => {
    const { services, occurrence, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [targetDown], "2026-10-13T09:55:00Z");

    await runAt("2026-10-13T10:00:00Z");
    await runAt("2026-10-13T10:05:00Z");

    expect(await occurrence(targetDown.sourceKey)).toMatchObject({ status: "firing" });
  });

  it("starts over when a notification arrives in between", async () => {
    const { services, occurrence, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z");

    await runAt("2026-10-13T10:00:00Z");
    await deliver(services, [targetDown], "2026-10-13T10:01:00Z");
    await runAt("2026-10-13T10:05:00Z");
    // Gone again once the grace after that notification has passed.
    await runAt("2026-10-13T10:12:00Z");
    await runAt("2026-10-13T10:16:00Z");
    expect(await occurrence(targetDown.sourceKey)).toMatchObject({ status: "firing" });

    await runAt("2026-10-13T10:17:00Z");
    expect(await occurrence(targetDown.sourceKey)).toMatchObject({
      status: "resolved",
      endsAt: "2026-10-13T10:12:00.000Z",
    });
  });

  it("starts over after a failed read: a restarted Alertmanager may not know its alerts yet", async () => {
    const { lab, services, occurrence, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z");

    await runAt("2026-10-13T10:00:00Z");
    lab.failReads(503, "restarting");
    await runAt("2026-10-13T10:03:00Z");
    lab.failReads(null);
    await runAt("2026-10-13T10:06:00Z");
    expect(await occurrence(targetDown.sourceKey)).toMatchObject({ status: "firing" });

    await runAt("2026-10-13T10:11:00Z");
    expect(await occurrence(targetDown.sourceKey)).toMatchObject({
      status: "resolved",
      endsAt: "2026-10-13T10:06:00.000Z",
    });
  });

  it("doesn't trust an Alertmanager listing no alerts at all", async () => {
    const { lab, services, occurrence, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [crashLoop, targetDown], "2026-10-13T09:00:00Z");
    lab.alerts.length = 0;

    await runAt("2026-10-13T10:00:00Z");
    await runAt("2026-10-13T10:05:00Z");
    await runAt("2026-10-13T10:10:00Z");

    expect(await occurrence(targetDown.sourceKey)).toMatchObject({ status: "firing" });
    expect(await occurrence(crashLoop.sourceKey)).toMatchObject({ status: "firing" });
  });

  it("reopens it when Alertmanager sends it again", async () => {
    const { services, occurrence, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z");
    await runAt("2026-10-13T10:00:00Z");
    await runAt("2026-10-13T10:05:00Z");

    await deliver(services, [targetDown], "2026-10-13T10:30:00Z");

    expect(await occurrence(targetDown.sourceKey)).toMatchObject({
      status: "firing",
      endsAt: null,
      lastEventKind: "reopened",
    });
  });

  it("leaves instances alone whose Alertmanager isn't configured or can't be read", async () => {
    const { lab, app, services, runAt } = await labWithCrashLoopOnly();
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z", "example-prod", "other");
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z");
    // Lab has crashLoop only; failing reads must keep targetDown firing there too.
    lab.failReads(503, "down");

    await runAt("2026-10-13T10:00:00Z");
    await runAt("2026-10-13T10:05:00Z");
    await runAt("2026-10-13T10:10:00Z");

    const { body } = await getJson(app, "/api/occurrences?status=firing");
    expect(body.occurrences.map((item: { instance: string }) => item.instance).sort()).toEqual([
      "lab",
      "other",
    ]);
  });
});
