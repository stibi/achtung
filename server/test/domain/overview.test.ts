import { describe, expect, it } from "vitest";
import {
  type AlertmanagerAlert,
  countAlerts,
  deliveryGraceMs,
  deliveryOf,
  longestFiring,
} from "../../src/domain/overview.ts";

const readAt = new Date("2026-10-13T10:00:00Z");
const minutesBefore = (minutes: number) => new Date(readAt.getTime() - minutes * 60_000);

function alert(
  name: string,
  fields: Partial<Omit<AlertmanagerAlert, "labels">> & { severity?: string } = {},
): AlertmanagerAlert {
  const { severity, ...rest } = fields;
  return {
    fingerprint: `fp-${name}`,
    labels: severity === undefined ? { alertname: name } : { alertname: name, severity },
    startsAt: minutesBefore(60),
    state: "active",
    silencedBy: [],
    inhibitedBy: [],
    receivers: ["team"],
    ...rest,
  };
}

const silenced = { state: "suppressed", silencedBy: ["s1"] } as const;
const inhibited = { state: "suppressed", inhibitedBy: ["fp-cause"] } as const;

describe("countAlerts", () => {
  it("counts nothing for an Alertmanager with no alerts", () => {
    expect(countAlerts([])).toEqual({
      open: { total: 0, critical: 0, warning: 0, info: 0, other: 0 },
      silenced: 0,
      inhibited: 0,
      watchdog: "absent",
    });
  });

  it("buckets notifying alerts by severity, unknown ones as other", () => {
    const counts = countAlerts([
      alert("A", { severity: "critical" }),
      alert("B", { severity: "critical" }),
      alert("C", { severity: "warning" }),
      alert("D", { severity: "Info" }),
      alert("E", { severity: "page" }),
      alert("F"),
    ]);

    expect(counts.open).toEqual({ total: 6, critical: 2, warning: 1, info: 1, other: 2 });
  });

  it("counts unprocessed alerts as open: they will notify", () => {
    expect(countAlerts([alert("A", { state: "unprocessed", severity: "warning" })]).open).toEqual({
      total: 1,
      critical: 0,
      warning: 1,
      info: 0,
      other: 0,
    });
  });

  it("counts silenced and inhibited alerts apart from the open ones", () => {
    const counts = countAlerts([
      alert("A", { ...silenced, severity: "critical" }),
      alert("B", { ...inhibited, severity: "critical" }),
      alert("C", { ...inhibited }),
      alert("D", { severity: "critical" }),
    ]);

    expect(counts).toMatchObject({
      open: { total: 1, critical: 1 },
      silenced: 1,
      inhibited: 2,
    });
  });

  it("counts an alert both silenced and inhibited as silenced only", () => {
    const both = alert("A", { state: "suppressed", silencedBy: ["s1"], inhibitedBy: ["fp-x"] });

    expect(countAlerts([both])).toMatchObject({ silenced: 1, inhibited: 0 });
  });

  it("goes by the state: an active alert naming a silence is open", () => {
    const active = alert("A", { silencedBy: ["s1"], severity: "warning" });

    expect(countAlerts([active])).toMatchObject({ open: { total: 1, warning: 1 }, silenced: 0 });
  });

  it("counts a suppressed alert neither silenced nor inhibited nowhere", () => {
    const muted = alert("A", { state: "suppressed", severity: "critical" });

    expect(countAlerts([muted])).toMatchObject({
      open: { total: 0, critical: 0 },
      silenced: 0,
      inhibited: 0,
    });
  });

  it("leaves out Watchdog and InfoInhibitor, in any state", () => {
    const counts = countAlerts([
      alert("Watchdog", { severity: "none" }),
      alert("InfoInhibitor", { severity: "none" }),
      alert("Watchdog", { ...silenced }),
      alert("InfoInhibitor", { ...inhibited }),
    ]);

    expect(counts).toMatchObject({ open: { total: 0, other: 0 }, silenced: 0, inhibited: 0 });
  });

  it("says whether the Watchdog fires, even when it is suppressed", () => {
    expect(countAlerts([alert("Watchdog")]).watchdog).toBe("firing");
    expect(countAlerts([alert("Watchdog", { ...silenced })]).watchdog).toBe("firing");
    expect(countAlerts([alert("InfoInhibitor"), alert("WatchdogX")]).watchdog).toBe("absent");
  });

  it("counts an alert without an alertname", () => {
    const nameless: AlertmanagerAlert = { ...alert("A"), labels: { severity: "info" } };

    expect(countAlerts([nameless]).open).toMatchObject({ total: 1, info: 1 });
  });
});

function firing(sourceKey: string, startedMinutesAgo: number, lastReceivedMinutesAgo: number) {
  return {
    sourceKey,
    startsAt: minutesBefore(startedMinutesAgo),
    lastReceivedAt: minutesBefore(lastReceivedMinutesAgo),
  };
}

const graceMinutes = deliveryGraceMs / 60_000;
const justOverGrace = (startsAt: Date) => new Date(startsAt.getTime() - 1);

describe("deliveryOf: missing in Achtung", () => {
  const receivers = new Set(["team"]);
  const missing = (
    alerts: AlertmanagerAlert[],
    firingKeys: string[] = [],
    changedAfterRead: { sourceKey: string; startsAt: Date }[] = [],
  ) =>
    deliveryOf(alerts, {
      receivers,
      firing: firingKeys.map((key) => firing(key, 60, 1)),
      changedAfterRead,
      readAt,
    }).missingInAchtung;

  it("expects a new firing even while an older occurrence of the alert still fires", () => {
    // fp-A fires in Achtung since 60 minutes ago; Alertmanager's firing started 30 ago.
    expect(missing([alert("A", { startsAt: minutesBefore(30) })], ["fp-A"])).toEqual([
      expect.objectContaining({ fingerprint: "fp-A", startsAt: minutesBefore(30) }),
    ]);
  });

  it("doesn't expect an alert that changed in Achtung after the read, e.g. resolved", () => {
    const changed = [{ sourceKey: "fp-A", startsAt: minutesBefore(60) }];
    const olderFiring = [{ sourceKey: "fp-B", startsAt: minutesBefore(90) }];

    expect(missing([alert("A"), alert("B")], [], [...changed, ...olderFiring])).toEqual([
      expect.objectContaining({ fingerprint: "fp-B" }),
    ]);
  });

  it("lists a notifying alert routed to Achtung that doesn't fire there", () => {
    const startsAt = minutesBefore(30);

    expect(missing([alert("A", { severity: "critical", startsAt })])).toEqual([
      { fingerprint: "fp-A", title: "A", severity: "critical", startsAt },
    ]);
  });

  it("leaves out an alert that fires in Achtung", () => {
    expect(missing([alert("A"), alert("B")], ["fp-A"])).toEqual([
      expect.objectContaining({ fingerprint: "fp-B" }),
    ]);
  });

  it("waits out the grace for notifications in flight", () => {
    const exactlyGrace = minutesBefore(graceMinutes);

    expect(missing([alert("A", { startsAt: exactlyGrace })])).toEqual([]);
    expect(missing([alert("A", { startsAt: justOverGrace(exactlyGrace) })])).toHaveLength(1);
  });

  it("only expects alerts routed to a receiver that delivers to Achtung", () => {
    expect(missing([alert("A", { receivers: ["null"] })])).toEqual([]);
    expect(missing([alert("A", { receivers: [] })])).toEqual([]);
    expect(missing([alert("A", { receivers: ["null", "team"] })])).toHaveLength(1);
  });

  it("expects nothing before Achtung has heard of any receiver", () => {
    const delivery = deliveryOf([alert("A")], {
      receivers: new Set(),
      firing: [],
      changedAfterRead: [],
      readAt,
    });

    expect(delivery.missingInAchtung).toEqual([]);
  });

  it("doesn't expect silenced or inhibited alerts, but does unprocessed ones", () => {
    expect(missing([alert("A", { ...silenced }), alert("B", { ...inhibited })])).toEqual([]);
    expect(missing([alert("A", { state: "unprocessed" })])).toHaveLength(1);
  });

  it("titles an alert without an alertname by its fingerprint", () => {
    const nameless: AlertmanagerAlert = { ...alert("A"), labels: {} };

    expect(missing([nameless])).toEqual([
      expect.objectContaining({ title: "fp-A", severity: "unknown" }),
    ]);
  });

  it("lists the oldest first", () => {
    const alerts = [
      alert("B", { startsAt: minutesBefore(20) }),
      alert("A", { startsAt: minutesBefore(40) }),
      alert("C", { startsAt: minutesBefore(30) }),
    ];

    expect(missing(alerts).map((item) => item.title)).toEqual(["A", "C", "B"]);
  });
});

describe("deliveryOf: stale in Achtung", () => {
  const stale = (alerts: AlertmanagerAlert[], occurrences: ReturnType<typeof firing>[]) =>
    deliveryOf(alerts, {
      receivers: new Set(["team"]),
      firing: occurrences,
      changedAfterRead: [],
      readAt,
    }).staleInAchtung;

  it("lists an occurrence whose alert has since fired again with a new start", () => {
    // A resolve muted by a silence never arrived (ADR 0008); the alert fired again later.
    const old = firing("fp-A", 120, 30);

    expect(stale([alert("A", { startsAt: minutesBefore(20) })], [old])).toEqual([old]);
  });

  it("lists an occurrence that fires in Achtung but is gone from Alertmanager", () => {
    const occurrence = firing("fp-gone", 60, 30);

    expect(stale([alert("A")], [occurrence, firing("fp-A", 60, 30)])).toEqual([occurrence]);
  });

  it("keeps an occurrence Alertmanager still has, in any state or route", () => {
    const alerts = [
      alert("A", { ...silenced }),
      alert("B", { ...inhibited }),
      alert("C", { receivers: ["null"] }),
    ];
    const occurrences = ["fp-A", "fp-B", "fp-C"].map((key) => firing(key, 60, 30));

    expect(stale(alerts, occurrences)).toEqual([]);
  });

  it("waits out the grace after the last notification", () => {
    const exactlyGrace = firing("fp-gone", 60, graceMinutes);
    const overGrace = {
      ...exactlyGrace,
      lastReceivedAt: justOverGrace(exactlyGrace.lastReceivedAt),
    };

    expect(stale([], [exactlyGrace])).toEqual([]);
    expect(stale([], [overGrace])).toEqual([overGrace]);
  });

  it("lists the oldest first", () => {
    const occurrences = [firing("b", 20, 15), firing("a", 40, 15), firing("c", 30, 15)];

    expect(stale([], occurrences).map((item) => item.sourceKey)).toEqual(["a", "c", "b"]);
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
