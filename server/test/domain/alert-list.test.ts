import { describe, expect, it } from "vitest";
import { type AlertmanagerAlert, alertListOf, countAlerts } from "../../src/domain/overview.ts";
import { alert, inhibited, minutesBefore, silenced } from "./alertmanager-alerts.ts";

describe("alertListOf", () => {
  const none = { occurrences: [], silences: [] };
  const names = (alerts: readonly AlertmanagerAlert[]) =>
    alertListOf(alerts, none).map((listed) => listed.title);

  it("lists an alert with what Alertmanager reported of it", () => {
    const disk = alert("DiskFilling", {
      severity: "Warning",
      annotations: { summary: "Disk is filling", description: "Long text" },
    });

    expect(alertListOf([disk], none)).toEqual([
      {
        fingerprint: "fp-DiskFilling",
        title: "DiskFilling",
        severity: "warning",
        summary: "Disk is filling",
        startsAt: minutesBefore(60),
        labels: { alertname: "DiskFilling", severity: "Warning" },
        annotations: { summary: "Disk is filling", description: "Long text" },
        state: "active",
        occurrenceId: null,
      },
    ]);
  });

  it("titles an alert without an alertname by its fingerprint, and has no summary without one", () => {
    const nameless: AlertmanagerAlert = { ...alert("A"), labels: {} };

    expect(alertListOf([nameless], none)[0]).toMatchObject({
      title: "fp-A",
      severity: "unknown",
      summary: null,
    });
  });

  it("stands each alert as the counts do", () => {
    const listed = alertListOf(
      [
        alert("Active"),
        alert("Unprocessed", { state: "unprocessed" }),
        alert("NamesASilence", { silencedBy: ["s1"] }),
        alert("Silenced", { ...silenced }),
        alert("Both", { state: "suppressed", silencedBy: ["s1"], inhibitedBy: ["fp-x"] }),
        alert("Inhibited", { ...inhibited }),
        alert("Muted", { state: "suppressed" }),
      ],
      none,
    );

    expect(Object.fromEntries(listed.map((item) => [item.title, item.state]))).toEqual({
      Active: "active",
      Unprocessed: "active",
      NamesASilence: "active",
      Silenced: "silenced",
      Both: "silenced",
      Inhibited: "inhibited",
    });
  });

  it("lists exactly what countAlerts counts", () => {
    const alerts = [
      alert("A", { severity: "critical" }),
      alert("B", { severity: "info", state: "unprocessed" }),
      alert("C", { ...silenced }),
      alert("D", { ...inhibited }),
      alert("E", { state: "suppressed" }),
      alert("Watchdog"),
      alert("InfoInhibitor", { ...inhibited }),
    ];
    const listed = alertListOf(alerts, none);
    const inState = (state: string) => listed.filter((item) => item.state === state).length;
    const counts = countAlerts(alerts);

    expect([inState("active"), inState("silenced"), inState("inhibited")]).toEqual([
      counts.open.total,
      counts.silenced,
      counts.inhibited,
    ]);
    expect(listed.map((item) => item.title)).toEqual(["A", "B", "C", "D"]);
  });

  it("leaves out Watchdog and InfoInhibitor, in any state", () => {
    expect(
      names([alert("Watchdog"), alert("InfoInhibitor", { ...silenced }), alert("WatchdogX")]),
    ).toEqual(["WatchdogX"]);
  });

  it("orders by severity, then the newest start first, then by fingerprint", () => {
    expect(
      names([
        alert("OtherNew", { startsAt: minutesBefore(1) }),
        alert("InfoOld", { severity: "info", startsAt: minutesBefore(50) }),
        alert("WarningOld", { severity: "warning", startsAt: minutesBefore(40) }),
        alert("CriticalOld", { severity: "critical", startsAt: minutesBefore(30) }),
        alert("WarningNew", { severity: "warning", startsAt: minutesBefore(5) }),
        alert("CriticalB", { severity: "critical", startsAt: minutesBefore(10) }),
        alert("CriticalA", { severity: "critical", startsAt: minutesBefore(10) }),
        alert("InfoNew", { severity: "info", startsAt: minutesBefore(20) }),
      ]),
    ).toEqual([
      "CriticalA",
      "CriticalB",
      "CriticalOld",
      "WarningNew",
      "WarningOld",
      "InfoNew",
      "InfoOld",
      "OtherNew",
    ]);
  });

  describe("occurrenceId", () => {
    const disk = alert("Disk", { startsAt: minutesBefore(30) });
    const occurrence = (id: number, sourceKey: string, startsAt: Date) => ({
      id,
      sourceKey,
      startsAt,
    });
    const idOf = (occurrences: Parameters<typeof alertListOf>[1]["occurrences"]) =>
      alertListOf([disk], { occurrences, silences: [] })[0]?.occurrenceId;

    it("is the occurrence of the same firing: fingerprint and start", () => {
      expect(idOf([occurrence(7, "fp-Disk", minutesBefore(30))])).toBe(7);
    });

    it("is null for an occurrence of an earlier firing of the alert", () => {
      expect(idOf([occurrence(7, "fp-Disk", minutesBefore(90))])).toBeNull();
    });

    it("is null for another alert's occurrence that started together", () => {
      expect(idOf([occurrence(7, "fp-Other", minutesBefore(30))])).toBeNull();
    });

    it("is the lowest id when two channels have the firing", () => {
      expect(
        idOf([
          occurrence(9, "fp-Disk", minutesBefore(30)),
          occurrence(4, "fp-Disk", minutesBefore(30)),
          occurrence(6, "fp-Disk", minutesBefore(30)),
        ]),
      ).toBe(4);
    });
  });

  describe("silencedUntil", () => {
    const silence = (id: string, endsAt: string) => ({ id, endsAt: new Date(endsAt) });
    const silences = [
      silence("s1", "2026-10-13T12:00:00Z"),
      silence("s2", "2026-10-13T18:00:00Z"),
      silence("s3", "2026-10-14T08:00:00Z"),
    ];
    const listedWith = (fields: Partial<AlertmanagerAlert>) =>
      alertListOf([alert("A", fields)], { occurrences: [], silences })[0];

    it("is when the latest of the silences muting it ends", () => {
      expect(listedWith({ state: "suppressed", silencedBy: ["s2", "s1"] })).toMatchObject({
        state: "silenced",
        silencedUntil: new Date("2026-10-13T18:00:00Z"),
      });
    });

    it("is null when none of its silences is known", () => {
      expect(listedWith({ state: "suppressed", silencedBy: ["s9"] })).toMatchObject({
        state: "silenced",
        silencedUntil: null,
      });
    });

    it("is absent unless silenced", () => {
      expect(listedWith({ silencedBy: ["s3"] })).not.toHaveProperty("silencedUntil");
      expect(listedWith({ ...inhibited })).not.toHaveProperty("silencedUntil");
    });
  });
});
