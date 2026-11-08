import { describe, expect, it } from "vitest";
import { crashLoop, deliver, getJson, targetDown, titles } from "../api.ts";
import { appWithDatabase } from "../app.ts";

describe("GET /api/instances/{instance}/channels/{slug}/occurrences", () => {
  it("lists one instance's channel, not the same name elsewhere", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z", "ops", "edge");

    expect(await titles(app, "/api/instances/lab/channels/ops/occurrences")).toEqual([
      "KubePodCrashLooping",
    ]);
    expect(await titles(app, "/api/instances/edge/channels/ops/occurrences")).toEqual([
      "TargetDown",
    ]);
  });

  it.each([
    ["an unknown instance", "/api/instances/nowhere/channels/ops/occurrences", 404],
    ["an invalid instance name", "/api/instances/Not_An_Instance/channels/ops/occurrences", 404],
    ["an invalid channel name", "/api/instances/lab/channels/Not_A_Channel/occurrences", 404],
    ["a cursor it never issued", "/api/instances/lab/channels/ops/occurrences?cursor=bm9wZQ", 400],
  ])("rejects %s", async (_, url, expected) => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");

    const { status, body } = await getJson(app, url);

    expect(status).toBe(expected);
    expect(body).toEqual({ error: expect.any(String) });
  });

  it("still answers by name alone, for the one channel that has it", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");

    expect(await titles(app, "/api/channels/ops/occurrences")).toEqual(["KubePodCrashLooping"]);
  });

  it("keeps the alert's other occurrences within its instance", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "edge");
    const [occurrence] = (await getJson(app, "/api/instances/lab/channels/ops/occurrences")).body
      .occurrences;

    const { body } = await getJson(app, `/api/occurrences/${occurrence.id}`);

    expect(body.otherOccurrences).toEqual([]);
  });

  it("answers by name alone with the default channel when several instances have it", async () => {
    const { app, services } = await appWithDatabase();
    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z", "ops", "lab");
    await deliver(services, [targetDown], "2026-10-13T08:35:00Z", "ops", "edge");
    expect((await getJson(app, "/api/channels/ops/occurrences")).status).toBe(404);

    await deliver(services, [crashLoop], "2026-10-13T08:40:00Z", "ops", "default");

    expect(await titles(app, "/api/channels/ops/occurrences")).toEqual(["KubePodCrashLooping"]);
  });
});
