import { describe, expect, it } from "vitest";
import { crashLoop, crashLoopResolved, deliver, getJson, targetDown } from "../api.ts";
import { appWithDatabase } from "../app.ts";

/** Each occurrence's title with what last happened to it, newest change first. */
async function feed(app: Awaited<ReturnType<typeof appWithDatabase>>["app"]) {
  const { body } = await getJson(app, "/api/occurrences");
  return body.occurrences.map(
    (o: { title: string; lastEventKind: string; lastEventAt: string }) =>
      `${o.title} ${o.lastEventKind} ${o.lastEventAt}`,
  );
}

describe("a resend of an alert that is still firing (ADR 0009)", () => {
  it("is nothing new within an hour of its last event", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");

    const summary = await deliver(services, [crashLoop], "2026-10-13T09:29:59Z");

    expect(summary).toEqual({ alerts: 1, new: 0, resolved: 0 });
    expect(await feed(app)).toEqual(["KubePodCrashLooping fired 2026-10-13T08:30:00.000Z"]);
  });

  it("resurfaces the alert after an hour, at most once an hour, without counting as new", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");
    await deliver(services, [targetDown], "2026-10-13T08:45:00Z");

    const summary = await deliver(services, [crashLoop], "2026-10-13T09:30:00Z");
    await deliver(services, [crashLoop], "2026-10-13T10:00:00Z");

    expect(summary).toEqual({ alerts: 1, new: 0, resolved: 0 });
    expect(await feed(app)).toEqual([
      "KubePodCrashLooping resent 2026-10-13T09:30:00.000Z",
      "TargetDown fired 2026-10-13T08:45:00.000Z",
    ]);
  });

  it("is part of the occurrence's history, and the next real event replaces it", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");
    await deliver(services, [crashLoop], "2026-10-13T09:30:00Z");
    await deliver(services, [crashLoop], "2026-10-13T10:30:00Z");
    await deliver(services, [crashLoopResolved], "2026-10-13T10:40:00Z");

    const { body: page } = await getJson(app, "/api/occurrences");
    const { body } = await getJson(app, `/api/occurrences/${page.occurrences[0].id}`);

    expect(body.occurrence.lastEventKind).toBe("resolved");
    expect(body.events.map((event: { kind: string }) => event.kind)).toEqual([
      "fired",
      "resent",
      "resent",
      "resolved",
    ]);
  });
});
