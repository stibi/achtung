import { describe, expect, it } from "vitest";
import type { IncomingAlert } from "../../src/domain/alert.ts";
import { alertmanagerSource } from "../../src/sources/alertmanager/index.ts";
import { loadFixture } from "../fixtures.ts";

function parseAlerts(name: string): readonly IncomingAlert[] {
  const result = alertmanagerSource.parse(loadFixture("alertmanager", name));
  if (!result.ok) {
    throw new Error(result.error);
  }
  return result.alerts;
}

describe("alertmanager source", () => {
  it("maps every alert in a firing group", () => {
    const [crashLoop, targetDown] = parseAlerts("firing");

    expect(crashLoop).toEqual({
      sourceKey: "5f0a2c3e9b1d4e7a",
      status: "firing",
      severity: "warning",
      title: "KubePodCrashLooping",
      summary: "Pod is crash looping.",
      labels: expect.objectContaining({ namespace: "example-prod", pod: "api-7c9d8b6f5-x2k4q" }),
      annotations: expect.objectContaining({ summary: "Pod is crash looping." }),
      startsAt: new Date("2026-10-13T08:15:30.123Z"),
      endsAt: null,
      links: [
        { kind: "source", url: expect.stringContaining("prometheus.example.com") },
        { kind: "runbook", url: expect.stringContaining("kubepodcrashlooping") },
      ],
    });
    expect(targetDown?.severity).toBe("critical");
    expect(targetDown?.links).toEqual([]);
  });

  it("keeps the same identity when the alert resolves", () => {
    const [firing] = parseAlerts("firing");
    const [resolved] = parseAlerts("resolved");

    expect(resolved?.sourceKey).toBe(firing?.sourceKey);
    expect(resolved?.startsAt).toEqual(firing?.startsAt);
    expect(resolved?.status).toBe("resolved");
    expect(resolved?.endsAt).toEqual(new Date("2026-10-13T08:42:00Z"));
  });

  it("treats a firing alert's endsAt as no end", () => {
    const payload = loadFixture("alertmanager", "firing") as {
      alerts: { endsAt: string }[];
    };
    payload.alerts[0]!.endsAt = "2026-10-13T08:20:30Z";

    const result = alertmanagerSource.parse(payload);

    expect(result).toMatchObject({ ok: true, alerts: [{ status: "firing", endsAt: null }, {}] });
  });

  it("reports alerts truncated by max_alerts", () => {
    const payload = { ...(loadFixture("alertmanager", "firing") as object), truncatedAlerts: 3 };

    expect(alertmanagerSource.parse(payload)).toMatchObject({ ok: true, truncatedAlerts: 3 });
  });

  it("rejects payloads that are not Alertmanager webhook v4", () => {
    const payload = { ...(loadFixture("alertmanager", "firing") as object), version: "3" };

    const result = alertmanagerSource.parse(payload);

    expect(result.ok).toBe(false);
  });

  it("falls back to unknown severity and fingerprint title", () => {
    const payload = loadFixture("alertmanager", "resolved") as {
      alerts: { labels: Record<string, string> }[];
    };
    payload.alerts[0]!.labels = {};

    const result = alertmanagerSource.parse(payload);

    expect(result).toMatchObject({
      ok: true,
      alerts: [{ severity: "unknown", title: "5f0a2c3e9b1d4e7a" }],
    });
  });
});
