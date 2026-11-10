import { describe, expect, it } from "vitest";
import {
  type AlertmanagerAlert,
  deliveryGraceMs,
  deliveryOf,
  goneFromAlertmanager,
} from "../../src/domain/overview.ts";
import {
  alert,
  inhibited,
  minutesBefore,
  nothingIgnored,
  readAt,
  silenced,
} from "./alertmanager-alerts.ts";

/** A firing occurrence of an alert named after its sourceKey, unless `alertname` says otherwise. */
function firing(
  sourceKey: string,
  startedMinutesAgo: number,
  lastReceivedMinutesAgo: number,
  alertname = sourceKey,
) {
  const labels: Record<string, string> = { alertname };
  return {
    sourceKey,
    startsAt: minutesBefore(startedMinutesAgo),
    lastReceivedAt: minutesBefore(lastReceivedMinutesAgo),
    labels,
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
    ignored: ReadonlySet<string> = nothingIgnored,
  ) =>
    deliveryOf(alerts, ignored, {
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
    const delivery = deliveryOf([alert("A")], nothingIgnored, {
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

  it("doesn't expect an ignored alert, matching its name exactly", () => {
    const alerts = [alert("Watchdog"), alert("watchdog"), alert("InfoInhibitor")];

    expect(
      missing(alerts, [], [], new Set(["Watchdog", "InfoInhibitor"])).map((item) => item.title),
    ).toEqual(["watchdog"]);
    expect(missing(alerts).map((item) => item.title)).toEqual([
      "Watchdog",
      "watchdog",
      "InfoInhibitor",
    ]);
  });

  it("titles an alert without an alertname by its fingerprint", () => {
    const nameless: AlertmanagerAlert = { ...alert("A"), labels: {} };

    expect(missing([nameless], [], [], new Set(["A"]))).toEqual([
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
  const stale = (
    alerts: AlertmanagerAlert[],
    occurrences: ReturnType<typeof firing>[],
    ignored: ReadonlySet<string> = nothingIgnored,
  ) =>
    deliveryOf(alerts, ignored, {
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

  it("doesn't list an occurrence of an ignored alert, matching its alertname exactly", () => {
    const occurrences = [
      firing("fp-1", 60, 30, "grafana-irm-heartbeat"),
      firing("fp-2", 60, 30, "Grafana-irm-heartbeat"),
      firing("fp-3", 60, 30, "Watchdog"),
    ];

    expect(stale([], occurrences, new Set(["grafana-irm-heartbeat"]))).toEqual([
      occurrences[1],
      occurrences[2],
    ]);
    expect(stale([], occurrences)).toEqual(occurrences);
  });

  it("lists an occurrence without an alertname, whatever is ignored", () => {
    const nameless = { ...firing("fp-gone", 60, 30), labels: {} };

    expect(stale([], [nameless], new Set(["fp-gone"]))).toEqual([nameless]);
  });

  it("lists the oldest first", () => {
    const occurrences = [firing("b", 20, 15), firing("a", 40, 15), firing("c", 30, 15)];

    expect(stale([], occurrences).map((item) => item.sourceKey)).toEqual(["a", "c", "b"]);
  });
});

describe("goneFromAlertmanager", () => {
  it("is the stale occurrences, ignored names included, in the order given", () => {
    const occurrences = [
      firing("gone", 60, 30, "grafana-irm-heartbeat"),
      firing("fp-A", 60, 30),
      firing("recent", 60, 5),
      firing("old", 90, 45),
    ];

    expect(
      goneFromAlertmanager([alert("A", { startsAt: minutesBefore(60) })], occurrences, readAt),
    ).toEqual([occurrences[0], occurrences[3]]);
  });
});
