import { describe, expect, it } from "vitest";
import { crashLoop, crashLoopResolved, deliver, getJson, targetDown, titles } from "../api.ts";
import { appWithDatabase } from "../app.ts";

describe("GET /api/channels", () => {
  it("lists channels by instance and name with what is firing in each", async () => {
    const { app, services } = await appWithDatabase();
    expect((await getJson(app, "/api/channels")).body).toEqual({ channels: [] });

    await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z");
    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z");
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z", "example-dev");

    expect((await getJson(app, "/api/channels")).body).toEqual({
      channels: [
        {
          instance: "lab",
          slug: "example-dev",
          firing: 1,
          lastEventAt: "2026-10-13T09:00:00.000Z",
        },
        {
          instance: "lab",
          slug: "example-prod",
          firing: 1,
          lastEventAt: "2026-10-13T08:45:00.000Z",
        },
      ],
    });
  });

  it("shows a channel that has no occurrences yet", async () => {
    const { app, services } = await appWithDatabase();

    await deliver(services, [], "2026-10-13T08:30:00Z");

    expect((await getJson(app, "/api/channels")).body).toEqual({
      channels: [{ instance: "lab", slug: "example-prod", firing: 0, lastEventAt: null }],
    });
  });
});

describe("GET /api/channels/{slug}/occurrences", () => {
  it("returns occurrences with every field the client shows", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");

    const { status, body } = await getJson(app, "/api/channels/example-prod/occurrences");

    expect(status).toBe(200);
    expect(body).toEqual({
      occurrences: [
        {
          id: expect.any(Number),
          instance: "lab",
          channel: "example-prod",
          source: "alertmanager",
          sourceKey: "5f0a2c3e9b1d4e7a",
          status: "firing",
          severity: "warning",
          title: "KubePodCrashLooping",
          summary: "Pod is crash looping.",
          labels: crashLoop.labels,
          annotations: crashLoop.annotations,
          links: crashLoop.links,
          startsAt: "2026-10-13T08:15:30.123Z",
          endsAt: null,
          firstReceivedAt: "2026-10-13T08:30:00.000Z",
          lastReceivedAt: "2026-10-13T08:30:00.000Z",
          lastEventAt: "2026-10-13T08:30:00.000Z",
          lastEventKind: "fired",
          notificationCount: 1,
          silencedUntil: null,
        },
      ],
      nextCursor: null,
    });
  });

  it("orders by the latest change; repeats are not a change, a resolve is", async () => {
    const { app, services } = await appWithDatabase();
    const url = "/api/channels/example-prod/occurrences";
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z");
    expect(await titles(app, url)).toEqual(["TargetDown", "KubePodCrashLooping"]);

    await deliver(services, [crashLoop], "2026-10-13T08:40:00Z");
    expect(await titles(app, url)).toEqual(["TargetDown", "KubePodCrashLooping"]);

    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z");
    expect(await titles(app, url)).toEqual(["KubePodCrashLooping", "TargetDown"]);
  });

  it("filters by status", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z");
    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z");

    const url = "/api/channels/example-prod/occurrences";
    expect(await titles(app, `${url}?status=firing`)).toEqual(["TargetDown"]);
    expect(await titles(app, `${url}?status=resolved`)).toEqual(["KubePodCrashLooping"]);
  });

  it("pages through every occurrence exactly once, also when they changed at the same time", async () => {
    const { app, services } = await appWithDatabase();
    const sameTime = Array.from({ length: 3 }, (_, i) => ({
      ...crashLoop,
      sourceKey: `same-time-${i}`,
    }));
    await deliver(services, sameTime, "2026-10-13T08:30:00Z");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z");

    const seen: string[] = [];
    let url: string | null = "/api/channels/example-prod/occurrences?limit=2";
    while (url !== null) {
      const { body } = await getJson(app, url);
      seen.push(...body.occurrences.map((o: { sourceKey: string }) => o.sourceKey));
      url =
        body.nextCursor === null
          ? null
          : `/api/channels/example-prod/occurrences?limit=2&cursor=${body.nextCursor}`;
    }

    expect(seen).toHaveLength(4);
    expect(new Set(seen).size).toBe(4);
    expect(seen[0]).toBe(targetDown.sourceKey);
  });

  it.each([
    ["an unknown channel", "/api/channels/no-such-channel/occurrences", 404],
    ["an invalid channel name", "/api/channels/Not_A_Channel/occurrences", 404],
    ["a cursor it never issued", "/api/channels/example-prod/occurrences?cursor=bm9wZQ", 400],
    ["a limit out of range", "/api/channels/example-prod/occurrences?limit=0", 400],
    ["an unknown status", "/api/channels/example-prod/occurrences?status=open", 400],
  ])("rejects %s", async (_, url, expected) => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");

    const { status, body } = await getJson(app, url);

    expect(status).toBe(expected);
    expect(body).toEqual({ error: expect.any(String) });
  });
});

describe("GET /api/occurrences/{id}", () => {
  it("returns the history and the alert's other occurrences", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");
    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z");
    const refire = { ...crashLoop, startsAt: new Date("2026-10-13T09:00:00Z") };
    await deliver(services, [refire], "2026-10-13T09:01:00Z");
    await deliver(services, [targetDown], "2026-10-13T09:02:00Z");
    const list = await getJson(app, "/api/channels/example-prod/occurrences?status=resolved");
    const first = list.body.occurrences[0];

    const { status, body } = await getJson(app, `/api/occurrences/${first.id}`);

    expect(status).toBe(200);
    expect(body.occurrence).toEqual(first);
    expect(body.events).toEqual([
      {
        id: expect.any(Number),
        kind: "fired",
        cause: null,
        recordedAt: "2026-10-13T08:30:00.000Z",
      },
      {
        id: expect.any(Number),
        kind: "resolved",
        cause: null,
        recordedAt: "2026-10-13T08:45:00.000Z",
      },
    ]);
    expect(body.otherOccurrences).toEqual([
      expect.objectContaining({ startsAt: "2026-10-13T09:00:00.000Z", status: "firing" }),
    ]);
  });

  it.each([
    ["an unknown id", "/api/occurrences/999999", 404],
    ["an id that is not a number", "/api/occurrences/abc", 400],
  ])("rejects %s", async (_, url, expected) => {
    const { app } = await appWithDatabase();

    const { status, body } = await getJson(app, url);

    expect(status).toBe(expected);
    expect(body).toEqual({ error: expect.any(String) });
  });
});
