import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import type { IncomingAlert } from "../../src/domain/alert.ts";
import { type ChannelSlug, parseChannelSlug } from "../../src/domain/channel.ts";
import type { Services } from "../../src/http/app.ts";
import { alertmanagerSource } from "../../src/sources/alertmanager/index.ts";
import { appWithDatabase } from "../app.ts";
import { loadFixture } from "../fixtures.ts";

function alertsFrom(fixture: "firing" | "resolved"): readonly IncomingAlert[] {
  const result = alertmanagerSource.parse(loadFixture("alertmanager", fixture));
  if (!result.ok) {
    throw new Error(result.error);
  }
  return result.alerts;
}

const [crashLoop, targetDown] = alertsFrom("firing") as [IncomingAlert, IncomingAlert];
const [crashLoopResolved] = alertsFrom("resolved") as [IncomingAlert];

/** Ingests through the real service, with a controlled clock so ordering is exact. */
function deliver(
  services: Services,
  alerts: readonly IncomingAlert[],
  at: string,
  channel = "example-prod",
) {
  return services.ingest({
    source: "alertmanager",
    channel: parseChannelSlug(channel) as ChannelSlug,
    alerts,
    receivedAt: new Date(at),
  });
}

async function getJson(app: FastifyInstance, url: string) {
  const response = await app.inject({ method: "GET", url });
  return { status: response.statusCode, body: response.json() };
}

async function titles(app: FastifyInstance, url: string): Promise<string[]> {
  const { body } = await getJson(app, url);
  return body.occurrences.map((occurrence: { title: string }) => occurrence.title);
}

describe("GET /api/channels", () => {
  it("lists channels by name with what is firing in each", async () => {
    const { app, services } = await appWithDatabase();
    expect((await getJson(app, "/api/channels")).body).toEqual({ channels: [] });

    await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z");
    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z");
    await deliver(services, [targetDown], "2026-10-13T09:00:00Z", "example-dev");

    expect((await getJson(app, "/api/channels")).body).toEqual({
      channels: [
        { slug: "example-dev", firing: 1, lastEventAt: "2026-10-13T09:00:00.000Z" },
        { slug: "example-prod", firing: 1, lastEventAt: "2026-10-13T08:45:00.000Z" },
      ],
    });
  });

  it("shows a channel that has no occurrences yet", async () => {
    const { app, services } = await appWithDatabase();

    await deliver(services, [], "2026-10-13T08:30:00Z");

    expect((await getJson(app, "/api/channels")).body).toEqual({
      channels: [{ slug: "example-prod", firing: 0, lastEventAt: null }],
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
          notificationCount: 1,
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
      { id: expect.any(Number), kind: "fired", recordedAt: "2026-10-13T08:30:00.000Z" },
      { id: expect.any(Number), kind: "resolved", recordedAt: "2026-10-13T08:45:00.000Z" },
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

describe("GET /api/occurrences", () => {
  const url = "/api/occurrences";

  async function rows(app: FastifyInstance, path = url): Promise<string[]> {
    const { body } = await getJson(app, path);
    return body.occurrences.map(
      (occurrence: { channel: string; title: string }) =>
        `${occurrence.channel}/${occurrence.title}`,
    );
  }

  it("lists every channel's occurrences, newest change first", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "example-prod");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z", "example-dev");
    await deliver(services, [crashLoop], "2026-10-13T08:40:00Z", "example-dev");

    const { status, body } = await getJson(app, url);

    expect(status).toBe(200);
    expect(body.nextCursor).toBeNull();
    expect(await rows(app)).toEqual([
      "example-dev/KubePodCrashLooping",
      "example-dev/TargetDown",
      "example-prod/KubePodCrashLooping",
    ]);
  });

  it("moves an occurrence on a resolve or reopen, not on a repeat", async () => {
    const { app, services } = await appWithDatabase();
    const targetDownResolved: IncomingAlert = {
      ...targetDown,
      status: "resolved",
      endsAt: new Date("2026-10-13T08:49:00Z"),
    };
    const devFirst = ["example-dev/TargetDown", "example-prod/KubePodCrashLooping"];
    const prodFirst = ["example-prod/KubePodCrashLooping", "example-dev/TargetDown"];
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "example-prod");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z", "example-dev");
    expect(await rows(app)).toEqual(devFirst);

    await deliver(services, [crashLoop], "2026-10-13T08:40:00Z", "example-prod");
    expect(await rows(app)).toEqual(devFirst);

    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z", "example-prod");
    expect(await rows(app)).toEqual(prodFirst);

    await deliver(services, [targetDownResolved], "2026-10-13T08:50:00Z", "example-dev");
    expect(await rows(app)).toEqual(devFirst);

    // The same startsAt firing again after its resolve reopens the occurrence.
    await deliver(services, [crashLoop], "2026-10-13T08:55:00Z", "example-prod");
    expect(await rows(app)).toEqual(prodFirst);
    expect((await getJson(app, url)).body.occurrences[0]).toEqual(
      expect.objectContaining({ status: "firing", lastEventAt: "2026-10-13T08:55:00.000Z" }),
    );
  });

  it("pages across channels exactly once, also when they changed at the same time", async () => {
    const { app, services } = await appWithDatabase();
    const sameTime = (prefix: string) =>
      Array.from({ length: 2 }, (_, i) => ({ ...crashLoop, sourceKey: `${prefix}-${i}` }));
    await deliver(services, sameTime("prod"), "2026-10-13T08:30:00Z", "example-prod");
    await deliver(services, sameTime("dev"), "2026-10-13T08:30:00Z", "example-dev");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z", "example-staging");

    const seen: string[] = [];
    let path: string | null = `${url}?limit=2`;
    while (path !== null) {
      const { body } = await getJson(app, path);
      seen.push(...body.occurrences.map((o: { sourceKey: string }) => o.sourceKey));
      path = body.nextCursor === null ? null : `${url}?limit=2&cursor=${body.nextCursor}`;
    }

    expect(seen).toHaveLength(5);
    expect(new Set(seen).size).toBe(5);
    expect(seen[0]).toBe(targetDown.sourceKey);
  });

  it("filters by status across channels", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "example-prod");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z", "example-dev");
    await deliver(services, [crashLoopResolved], "2026-10-13T08:45:00Z", "example-prod");

    expect(await rows(app, `${url}?status=firing`)).toEqual(["example-dev/TargetDown"]);
    expect(await rows(app, `${url}?status=resolved`)).toEqual(["example-prod/KubePodCrashLooping"]);
  });

  it("is empty before anything arrives", async () => {
    const { app } = await appWithDatabase();

    expect((await getJson(app, url)).body).toEqual({ occurrences: [], nextCursor: null });
  });

  it.each([
    ["a cursor it never issued", `${url}?cursor=bm9wZQ`],
    ["a limit out of range", `${url}?limit=201`],
    ["an unknown status", `${url}?status=open`],
  ])("rejects %s", async (_, path) => {
    const { app } = await appWithDatabase();

    const { status, body } = await getJson(app, path);

    expect(status).toBe(400);
    expect(body).toEqual({ error: expect.any(String) });
  });
});

describe("caching", () => {
  it.each([
    ["a list", "/api/channels"],
    ["an error", "/api/occurrences?cursor=bm9wZQ"],
  ])("tells clients and proxies not to store %s", async (_, url) => {
    const { app } = await appWithDatabase();

    const response = await app.inject({ method: "GET", url });

    expect(response.headers["cache-control"]).toBe("no-store");
  });

  it("leaves routes outside the client API alone", async () => {
    const { app } = await appWithDatabase();

    const response = await app.inject({ method: "GET", url: "/healthz" });

    expect(response.headers["cache-control"]).toBeUndefined();
  });
});
