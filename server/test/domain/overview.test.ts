import { describe, expect, it } from "vitest";
import { type AlertmanagerAlert, countAlerts, longestFiring } from "../../src/domain/overview.ts";
import { alert, inhibited, nothingIgnored, silenced } from "./alertmanager-alerts.ts";

describe("countAlerts", () => {
  it("counts nothing for an Alertmanager with no alerts", () => {
    expect(countAlerts([], nothingIgnored)).toEqual({
      open: { total: 0, critical: 0, warning: 0, info: 0, other: 0 },
      silenced: 0,
      inhibited: 0,
      watchdog: "absent",
    });
  });

  it("buckets notifying alerts by severity, unknown ones as other", () => {
    const counts = countAlerts(
      [
        alert("A", { severity: "critical" }),
        alert("B", { severity: "critical" }),
        alert("C", { severity: "warning" }),
        alert("D", { severity: "Info" }),
        alert("E", { severity: "page" }),
        alert("F"),
      ],
      nothingIgnored,
    );

    expect(counts.open).toEqual({ total: 6, critical: 2, warning: 1, info: 1, other: 2 });
  });

  it("counts unprocessed alerts as open: they will notify", () => {
    expect(
      countAlerts([alert("A", { state: "unprocessed", severity: "warning" })], nothingIgnored).open,
    ).toEqual({
      total: 1,
      critical: 0,
      warning: 1,
      info: 0,
      other: 0,
    });
  });

  it("counts silenced and inhibited alerts apart from the open ones", () => {
    const counts = countAlerts(
      [
        alert("A", { ...silenced, severity: "critical" }),
        alert("B", { ...inhibited, severity: "critical" }),
        alert("C", { ...inhibited }),
        alert("D", { severity: "critical" }),
      ],
      nothingIgnored,
    );

    expect(counts).toMatchObject({
      open: { total: 1, critical: 1 },
      silenced: 1,
      inhibited: 2,
    });
  });

  it("counts an alert both silenced and inhibited as silenced only", () => {
    const both = alert("A", { state: "suppressed", silencedBy: ["s1"], inhibitedBy: ["fp-x"] });

    expect(countAlerts([both], nothingIgnored)).toMatchObject({ silenced: 1, inhibited: 0 });
  });

  it("goes by the state: an active alert naming a silence is open", () => {
    const active = alert("A", { silencedBy: ["s1"], severity: "warning" });

    expect(countAlerts([active], nothingIgnored)).toMatchObject({
      open: { total: 1, warning: 1 },
      silenced: 0,
    });
  });

  it("counts a suppressed alert neither silenced nor inhibited nowhere", () => {
    const muted = alert("A", { state: "suppressed", severity: "critical" });

    expect(countAlerts([muted], nothingIgnored)).toMatchObject({
      open: { total: 0, critical: 0 },
      silenced: 0,
      inhibited: 0,
    });
  });

  it("leaves out the ignored alert names, in any state", () => {
    const ignored = new Set(["Watchdog", "grafana-irm-heartbeat"]);
    const counts = countAlerts(
      [
        alert("Watchdog", { severity: "none" }),
        alert("grafana-irm-heartbeat", { severity: "critical" }),
        alert("Watchdog", { ...silenced }),
        alert("grafana-irm-heartbeat", { ...inhibited }),
        alert("InfoInhibitor", { severity: "none" }),
      ],
      ignored,
    );

    expect(counts).toEqual({
      open: { total: 1, critical: 0, warning: 0, info: 0, other: 1 },
      silenced: 0,
      inhibited: 0,
      watchdog: "firing",
    });
  });

  it("matches an ignored name exactly and case-sensitively", () => {
    const ignored = new Set(["Watchdog"]);
    const counts = countAlerts(
      [alert("watchdog"), alert("WatchdogX"), alert("Watch"), alert(" Watchdog")],
      ignored,
    );

    expect(counts.open.total).toBe(4);
  });

  it("counts every alert when nothing is ignored, Watchdog too", () => {
    const counts = countAlerts(
      [alert("Watchdog", { severity: "none" }), alert("InfoInhibitor", { ...inhibited })],
      nothingIgnored,
    );

    expect(counts).toEqual({
      open: { total: 1, critical: 0, warning: 0, info: 0, other: 1 },
      silenced: 0,
      inhibited: 1,
      watchdog: "firing",
    });
  });

  it("never ignores an alert without an alertname", () => {
    const nameless: AlertmanagerAlert = { ...alert("A"), labels: {} };

    expect(countAlerts([nameless], new Set(["A", "fp-A"])).open.total).toBe(1);
  });

  it("says the Watchdog fires while it is ignored: the heart doesn't depend on the list", () => {
    const ignored = new Set(["Watchdog"]);

    expect(countAlerts([alert("Watchdog")], ignored).watchdog).toBe("firing");
    expect(countAlerts([alert("Watchdog", { ...inhibited })], ignored).watchdog).toBe("firing");
    expect(countAlerts([], ignored).watchdog).toBe("absent");
  });

  it("says whether the Watchdog fires, even when it is suppressed", () => {
    expect(countAlerts([alert("Watchdog")], nothingIgnored).watchdog).toBe("firing");
    expect(countAlerts([alert("Watchdog", { ...silenced })], nothingIgnored).watchdog).toBe(
      "firing",
    );
    expect(countAlerts([alert("InfoInhibitor"), alert("WatchdogX")], nothingIgnored).watchdog).toBe(
      "absent",
    );
  });

  it("counts an alert without an alertname", () => {
    const nameless: AlertmanagerAlert = { ...alert("A"), labels: { severity: "info" } };

    expect(countAlerts([nameless], nothingIgnored).open).toMatchObject({ total: 1, info: 1 });
  });
});

describe("longestFiring", () => {
  const occurrence = (id: number, startsAt: string) => ({ id, startsAt: new Date(startsAt) });

  it("is the earliest started, up to the limit", () => {
    const occurrences = [
      occurrence(1, "2026-10-13T09:00:00Z"),
      occurrence(2, "2026-10-13T07:00:00Z"),
      occurrence(3, "2026-10-13T08:00:00Z"),
    ];

    expect(longestFiring(occurrences, 2).map((item) => item.id)).toEqual([2, 3]);
  });

  it("orders occurrences that started together by id", () => {
    const occurrences = [
      occurrence(5, "2026-10-13T09:00:00Z"),
      occurrence(4, "2026-10-13T09:00:00Z"),
    ];

    expect(longestFiring(occurrences, 10).map((item) => item.id)).toEqual([4, 5]);
  });
});
