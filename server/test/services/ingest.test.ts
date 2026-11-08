import { asc } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import type { Database } from "../../src/db/client.ts";
import { channels, events, occurrences } from "../../src/db/schema.ts";
import type { IncomingAlert } from "../../src/domain/alert.ts";
import { type ChannelSlug, parseChannelSlug, parseInstanceName } from "../../src/domain/channel.ts";
import { ingestNotification } from "../../src/services/ingest.ts";
import { alertmanagerSource } from "../../src/sources/alertmanager/index.ts";
import { createTestDatabase, openConnections } from "../database.ts";
import { loadFixture } from "../fixtures.ts";

function alertsFrom(fixture: "firing" | "resolved"): readonly IncomingAlert[] {
  const result = alertmanagerSource.parse(loadFixture("alertmanager", fixture));
  if (!result.ok) {
    throw new Error(result.error);
  }
  return result.alerts;
}

const lab = parseInstanceName("lab")!;

function slug(value: string): ChannelSlug {
  return parseChannelSlug(value)!;
}

function deliver(
  db: Database,
  alerts: readonly IncomingAlert[],
  { channel = "example-prod", at = "2026-10-13T08:30:00Z", instance = lab } = {},
) {
  return ingestNotification(db, {
    source: "alertmanager",
    channel: { instance, slug: slug(channel) },
    alerts,
    receivedAt: new Date(at),
  });
}

async function eventKinds(db: Database): Promise<string[]> {
  const rows = await db.select({ kind: events.kind }).from(events).orderBy(asc(events.id));
  return rows.map((row) => row.kind);
}

const firing = alertsFrom("firing");
const resolved = alertsFrom("resolved");
const crashLoop = firing[0]!;

describe("ingestNotification", () => {
  it("stores a new firing group as new occurrences in an auto-created channel", async () => {
    const { db } = await createTestDatabase();

    const summary = await deliver(db, firing);

    expect(summary).toEqual({ alerts: 2, new: 2, resolved: 0 });
    expect(await db.select({ slug: channels.slug }).from(channels)).toEqual([
      { slug: "example-prod" },
    ]);
    expect(await eventKinds(db)).toEqual(["fired", "fired"]);
    const [stored] = await db
      .select()
      .from(occurrences)
      .orderBy(asc(occurrences.sourceKey))
      .limit(1);
    expect(stored).toMatchObject({
      sourceKey: crashLoop.sourceKey,
      status: "firing",
      endsAt: null,
      title: "KubePodCrashLooping",
      labels: crashLoop.labels,
      links: crashLoop.links,
      notificationCount: 1,
    });
  });

  it("updates a repeat notification in place without counting it as new", async () => {
    const { db } = await createTestDatabase();
    await deliver(db, firing);

    const summary = await deliver(db, firing, { at: "2026-10-13T12:30:00Z" });

    expect(summary).toEqual({ alerts: 2, new: 0, resolved: 0 });
    expect(await eventKinds(db)).toEqual(["fired", "fired"]);
    const rows = await db.select().from(occurrences);
    expect(rows).toHaveLength(2);
    expect(rows.map((row) => row.notificationCount)).toEqual([2, 2]);
    expect(rows[0]?.firstReceivedAt).toEqual(new Date("2026-10-13T08:30:00Z"));
    expect(rows[0]?.lastReceivedAt).toEqual(new Date("2026-10-13T12:30:00Z"));
  });

  it("resolves a firing occurrence once", async () => {
    const { db } = await createTestDatabase();
    await deliver(db, firing);

    const first = await deliver(db, resolved);
    const repeat = await deliver(db, resolved);

    expect(first).toEqual({ alerts: 1, new: 0, resolved: 1 });
    expect(repeat).toEqual({ alerts: 1, new: 0, resolved: 0 });
    expect(await eventKinds(db)).toEqual(["fired", "fired", "resolved"]);
    const rows = await db.select().from(occurrences).orderBy(asc(occurrences.sourceKey));
    expect(rows.map((row) => [row.status, row.endsAt])).toEqual([
      ["resolved", new Date("2026-10-13T08:42:00Z")],
      ["firing", null],
    ]);
  });

  it("records a resolve for an occurrence it never saw firing", async () => {
    const { db } = await createTestDatabase();

    const summary = await deliver(db, resolved);

    expect(summary).toEqual({ alerts: 1, new: 0, resolved: 1 });
    expect(await eventKinds(db)).toEqual(["resolved"]);
  });

  it("reopens an occurrence that fires again with the same start", async () => {
    const { db } = await createTestDatabase();
    await deliver(db, [crashLoop]);
    await deliver(db, resolved);

    const summary = await deliver(db, [crashLoop]);

    expect(summary).toEqual({ alerts: 1, new: 1, resolved: 0 });
    expect(await eventKinds(db)).toEqual(["fired", "resolved", "reopened"]);
    expect(await db.select({ status: occurrences.status }).from(occurrences)).toEqual([
      { status: "firing" },
    ]);
  });

  it("treats a re-fire with a new start as a new occurrence", async () => {
    const { db } = await createTestDatabase();
    await deliver(db, [crashLoop]);
    await deliver(db, resolved);

    const summary = await deliver(db, [
      { ...crashLoop, startsAt: new Date("2026-10-13T09:00:00Z") },
    ]);

    expect(summary).toEqual({ alerts: 1, new: 1, resolved: 0 });
    expect(await eventKinds(db)).toEqual(["fired", "resolved", "fired"]);
    expect(await db.select().from(occurrences)).toHaveLength(2);
  });

  it("keeps the same alert in different channels apart", async () => {
    const { db } = await createTestDatabase();

    await deliver(db, firing, { channel: "example-prod" });
    const summary = await deliver(db, firing, { channel: "example-dev" });

    expect(summary.new).toBe(2);
    expect(await db.select().from(channels)).toHaveLength(2);
    expect(await db.select().from(occurrences)).toHaveLength(4);
  });

  it("counts each occurrence as new once when overlapping notifications arrive concurrently", async () => {
    const connection = await createTestDatabase();
    const { db } = connection;
    await openConnections(connection, 10);
    // Opposite orders: without a fixed lock order these deadlock.
    const reversed = firing.toReversed();

    const summaries = await Promise.all(
      Array.from({ length: 10 }, (_, i) => deliver(db, i % 2 === 0 ? firing : reversed)),
    );

    expect(summaries.reduce((total, summary) => total + summary.new, 0)).toBe(2);
    expect(await eventKinds(db)).toEqual(["fired", "fired"]);
    const rows = await db.select().from(occurrences);
    expect(rows.map((row) => row.notificationCount)).toEqual([10, 10]);
  });

  it("resolves an occurrence once when resolves arrive concurrently", async () => {
    const connection = await createTestDatabase();
    const { db } = connection;
    await deliver(db, firing);
    await openConnections(connection, 10);

    const summaries = await Promise.all(Array.from({ length: 10 }, () => deliver(db, resolved)));

    expect(summaries.reduce((total, summary) => total + summary.resolved, 0)).toBe(1);
    expect(await eventKinds(db)).toEqual(["fired", "fired", "resolved"]);
  });

  it("keeps a channel whole when it moves to an instance while the old URL delivers", async () => {
    const connection = await createTestDatabase();
    const { db, pool } = connection;
    const byNameOnly = (alerts: readonly IncomingAlert[]) =>
      ingestNotification(db, {
        source: "alertmanager",
        channel: { instance: null, slug: slug("ops") },
        alerts,
        receivedAt: new Date("2026-10-13T08:45:00Z"),
      });
    await byNameOnly(firing);
    await openConnections(connection, 2);

    // The operator's one-off move (ADR 0006), still open while a resolve arrives.
    const operator = await pool.connect();
    await operator.query("begin");
    await operator.query("update channels set instance = 'lab' where instance = 'default'");
    const delivery = byNameOnly(resolved);
    await new Promise((settle) => setTimeout(settle, 200));
    await operator.query("commit");
    operator.release();
    await delivery;

    const rows = await db
      .select({ instance: channels.instance, slug: channels.slug })
      .from(channels);
    expect(rows).toEqual([{ instance: "lab", slug: "ops" }]);
    expect(await eventKinds(db)).toEqual(["fired", "fired", "resolved"]);
  });
});
