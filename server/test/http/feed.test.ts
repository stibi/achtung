import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import type { IncomingAlert } from "../../src/domain/alert.ts";
import { crashLoop, crashLoopResolved, deliver, getJson, targetDown } from "../api.ts";
import { appWithDatabase } from "../app.ts";

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
