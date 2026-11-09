import { describe, expect, it } from "vitest";
import type { IncomingAlert } from "../../src/domain/alert.ts";
import { startAlertmanagerStub } from "../alertmanager-stub.ts";
import { crashLoop, deliver, getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";

const at10 = () => new Date("2026-10-13T10:00:00Z");
const atTen = { silences: { now: at10 }, alerts: { now: at10 }, now: at10 };

function alert(name: string, startsAt: string): IncomingAlert {
  return {
    ...crashLoop,
    sourceKey: `fp-${name}`,
    title: name,
    labels: { ...crashLoop.labels, alertname: name },
    startsAt: new Date(startsAt),
  };
}

function resolve(firing: IncomingAlert, endsAt: string): IncomingAlert {
  return { ...firing, status: "resolved", endsAt: new Date(endsAt) };
}

describe("GET /api/home: noisiest alerts", () => {
  it("ranks alerts by fired, reopened and resent events in the last 24 hours", async () => {
    const { app, services } = await appWithDatabase(atTen);
    const send = (alerts: IncomingAlert[], at: string) => deliver(services, alerts, at);

    // Fired, reopened (same start after a resolve), then fired again with a new start.
    const flappy = alert("Flappy", "2026-10-13T07:59:00Z");
    await send([flappy], "2026-10-13T08:00:00Z");
    await send([resolve(flappy, "2026-10-13T08:10:00Z")], "2026-10-13T08:10:00Z");
    await send([flappy], "2026-10-13T08:20:00Z");
    await send([resolve(flappy, "2026-10-13T08:30:00Z")], "2026-10-13T08:30:00Z");
    const flappyAgain = alert("Flappy", "2026-10-13T08:39:00Z");
    await send([flappyAgain], "2026-10-13T08:40:00Z");
    // Fired, then resent an hour later; its resolve doesn't count.
    const resent = alert("Resent", "2026-10-13T07:59:00Z");
    await send([resent], "2026-10-13T08:00:00Z");
    await send([resent], "2026-10-13T09:00:00Z");
    await send([resolve(resent, "2026-10-13T09:10:00Z")], "2026-10-13T09:10:00Z");
    // Also two events, but the latest one is older: ranked after Resent.
    const earlier = alert("Earlier", "2026-10-13T06:59:00Z");
    await send([earlier], "2026-10-13T07:00:00Z");
    await send([earlier], "2026-10-13T08:05:00Z");
    // One event is no noise.
    await send([alert("Once", "2026-10-13T08:59:00Z")], "2026-10-13T09:00:00Z");
    // Its first firing is exactly 24 hours ago, outside the window.
    const old = alert("Old", "2026-10-12T09:59:00Z");
    await send([old], "2026-10-12T10:00:00Z");
    await send([resolve(old, "2026-10-12T10:10:00Z")], "2026-10-12T10:10:00Z");
    await send([alert("Old", "2026-10-13T09:29:00Z")], "2026-10-13T09:30:00Z");

    const { body } = await getJson(app, "/api/home");

    expect(
      body.noisiest.map(
        (noisy: { occurrence: { title: string; startsAt: string }; events: number }) => [
          noisy.occurrence.title,
          noisy.occurrence.startsAt,
          noisy.events,
        ],
      ),
    ).toEqual([
      ["Flappy", "2026-10-13T08:39:00.000Z", 3],
      ["Resent", "2026-10-13T07:59:00.000Z", 2],
      ["Earlier", "2026-10-13T06:59:00.000Z", 2],
    ]);
  });

  it("shows at most 10", async () => {
    const { app, services } = await appWithDatabase(atTen);
    const alerts = Array.from({ length: 11 }, (_, i) => alert(`A${i}`, "2026-10-13T06:59:00Z"));
    await deliver(services, alerts, "2026-10-13T07:00:00Z");
    await deliver(services, alerts, "2026-10-13T08:00:00Z");

    const { body } = await getJson(app, "/api/home");

    expect(body.noisiest).toHaveLength(10);
  });
});

describe("GET /api/home: longest firing", () => {
  it("lists firing occurrences, the earliest start first, at most 10, with their silence", async () => {
    const lab = await startAlertmanagerStub();
    lab.silences.push({
      id: "maintenance",
      status: { state: "active" },
      matchers: [{ name: "alertname", value: "A3", isRegex: false }],
      startsAt: "2026-10-13T08:00:00Z",
      endsAt: "2026-10-13T20:00:00Z",
      createdBy: "someone",
      comment: "maintenance",
    });
    const { app, services } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      ...atTen,
    });
    const alerts = Array.from({ length: 12 }, (_, i) =>
      alert(`A${i}`, `2026-10-13T0${Math.floor(i / 2)}:${i % 2 === 0 ? "30" : "00"}:00Z`),
    );
    await deliver(services, alerts, "2026-10-13T09:00:00Z");
    await deliver(services, [resolve(alerts[1]!, "2026-10-13T09:05:00Z")], "2026-10-13T09:05:00Z");

    const { body } = await getJson(app, "/api/home");

    const longest = body.longestFiring as { title: string; silencedUntil: string | null }[];
    expect(longest.map((occurrence) => occurrence.title)).toEqual([
      "A0",
      "A3",
      "A2",
      "A5",
      "A4",
      "A7",
      "A6",
      "A9",
      "A8",
      "A11",
    ]);
    expect(longest[1]?.silencedUntil).toBe("2026-10-13T20:00:00.000Z");
    expect(longest[0]?.silencedUntil).toBeNull();
  });
});
