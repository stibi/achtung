import { describe, expect, it } from "vitest";
import { resolveVanished } from "../../src/db/occurrences.ts";
import { listEvents, listFiringOccurrences } from "../../src/db/queries.ts";
import { parseChannelSlug, parseInstanceName } from "../../src/domain/channel.ts";
import { ingestNotification } from "../../src/services/ingest.ts";
import { crashLoop } from "../api.ts";
import { createTestDatabase } from "../database.ts";

// The conditional resolve behind ADR 0014: a notification since the read wins.

async function firingCrashLoop() {
  const { db } = await createTestDatabase();
  const deliver = (at: string) =>
    ingestNotification(db, {
      source: "alertmanager",
      channel: {
        instance: parseInstanceName("lab"),
        slug: parseChannelSlug("example-prod"),
      } as Parameters<typeof ingestNotification>[1]["channel"],
      alerts: [crashLoop],
      receiver: null,
      receivedAt: new Date(at),
    });
  await deliver("2026-10-13T09:00:00Z");
  const [occurrence] = await listFiringOccurrences(db);
  if (occurrence === undefined) {
    throw new Error("crashLoop isn't firing");
  }
  const resolve = (lastReceivedAt: Date) =>
    db.transaction((tx) =>
      resolveVanished(
        tx,
        occurrence.id,
        { lastReceivedAt, endsAt: new Date("2026-10-13T10:00:00Z") },
        new Date("2026-10-13T10:05:00Z"),
      ),
    );
  return { db, occurrence, deliver, resolve };
}

describe("resolveVanished", () => {
  it("resolves the occurrence as it was read, once", async () => {
    const { db, occurrence, resolve } = await firingCrashLoop();

    expect(await resolve(occurrence.lastReceivedAt)).toBe(true);
    expect(await resolve(occurrence.lastReceivedAt)).toBe(false);

    expect(await listFiringOccurrences(db)).toEqual([]);
    expect((await listEvents(db, occurrence.id)).map(({ kind, cause }) => [kind, cause])).toEqual([
      ["fired", null],
      ["resolved", "vanished"],
    ]);
  });

  it("leaves it firing when a notification arrived after the read", async () => {
    const { db, occurrence, deliver, resolve } = await firingCrashLoop();
    await deliver("2026-10-13T09:30:00Z");

    expect(await resolve(occurrence.lastReceivedAt)).toBe(false);

    expect(await listFiringOccurrences(db)).toEqual([
      expect.objectContaining({ id: occurrence.id, status: "firing" }),
    ]);
    expect((await listEvents(db, occurrence.id)).map(({ kind }) => kind)).toEqual(["fired"]);
  });
});
