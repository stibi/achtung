import { describe, expect, it } from "vitest";
import { type IrmAlertGroup, irmHeartbeatOf } from "../../src/domain/irm-heartbeat.ts";

const integration = "CINTEGRATION1";
const created = new Date("2026-10-13T09:00:00Z");
const resolved = new Date("2026-10-13T09:02:00Z");

function group(
  state: IrmAlertGroup["state"],
  {
    title = "OnCallHeartBeatMissing ",
    integrationId = integration,
    createdAt = created,
    resolvedAt = state === "resolved" ? resolved : null,
  }: Partial<Omit<IrmAlertGroup, "state">> = {},
): IrmAlertGroup {
  return { integrationId, title, state, createdAt, resolvedAt };
}

describe("irmHeartbeatOf", () => {
  it("is receiving, never missed, without any group", () => {
    expect(irmHeartbeatOf(integration, [])).toEqual({ status: "receiving", lastMissed: null });
  });

  it("is receiving when the latest group is resolved, and says when it was missed", () => {
    expect(irmHeartbeatOf(integration, [group("resolved")])).toEqual({
      status: "receiving",
      lastMissed: { from: created, to: resolved },
    });
  });

  it("is receiving, without a last miss, when IRM resolved a group without saying when", () => {
    expect(irmHeartbeatOf(integration, [group("resolved", { resolvedAt: null })])).toEqual({
      status: "receiving",
      lastMissed: null,
    });
  });

  it.each(["new", "acknowledged", "silenced"] as const)(
    "is missing since the group opened while it is %s",
    (state) => {
      expect(irmHeartbeatOf(integration, [group(state), group("resolved")])).toEqual({
        status: "missing",
        since: created,
      });
    },
  );

  it("goes by the newest group, whatever order IRM lists them in", () => {
    const earlier = new Date("2026-10-12T09:00:00Z");
    expect(
      irmHeartbeatOf(integration, [group("new", { createdAt: earlier }), group("resolved")]),
    ).toEqual({ status: "receiving", lastMissed: { from: created, to: resolved } });
  });

  it("goes by the newest group only", () => {
    const earlier = new Date("2026-10-12T09:00:00Z");
    expect(
      irmHeartbeatOf(integration, [group("resolved"), group("new", { createdAt: earlier })]),
    ).toEqual({ status: "receiving", lastMissed: { from: created, to: resolved } });
  });

  it.each(["OnCallHeartBeatMissing", "OnCallHeartBeatMissing ", "  OnCallHeartBeatMissing\n"])(
    "matches the title %j, whatever whitespace surrounds it",
    (title) => {
      expect(irmHeartbeatOf(integration, [group("new", { title })]).status).toBe("missing");
    },
  );

  it("skips groups the name filter matched that aren't a missed heartbeat", () => {
    const groups = [
      group("new", { title: "OnCallHeartBeatMissing for another check" }),
      group("new", { title: "oncallheartbeatmissing" }),
      group("resolved"),
    ];
    expect(irmHeartbeatOf(integration, groups)).toEqual({
      status: "receiving",
      lastMissed: { from: created, to: resolved },
    });
  });

  it("skips another integration's groups", () => {
    expect(irmHeartbeatOf(integration, [group("new", { integrationId: "COTHER" })])).toEqual({
      status: "receiving",
      lastMissed: null,
    });
  });
});
