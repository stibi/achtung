import { describe, expect, it } from "vitest";
import { crashLoop, deliver, getJson, targetDown, titles } from "../api.ts";
import { appWithDatabase } from "../app.ts";

// Finding alerts across channels by text, label, severity and instance (ADR 0017).

async function inbox() {
  const { app, services } = await appWithDatabase();
  const diskFull = {
    ...targetDown,
    sourceKey: "fp-disk",
    title: "DiskFull_50%",
    summary: "Volume data-db-0 is almost full.",
    severity: "info" as const,
    labels: {
      alertname: "DiskFull_50%",
      namespace: "payments",
      pod: "db-0",
      severity: "info",
      query: 'used{path="C:\\data"}=1',
    },
  };
  await deliver(services, [crashLoop, targetDown], "2026-10-13T08:30:00Z", "ops", "lab");
  await deliver(services, [diskFull], "2026-10-13T08:40:00Z", "payments", "prod");
  return { app };
}

const search = async (app: Parameters<typeof titles>[0], query: string) =>
  (await titles(app, `/api/occurrences?${query}`)).toSorted();

describe("searching occurrences", () => {
  it("finds text in the title, summary or a label, ignoring case", async () => {
    const { app } = await inbox();

    expect(await search(app, "q=crash")).toEqual(["KubePodCrashLooping"]);
    expect(await search(app, "q=UNREACHABLE")).toEqual(["TargetDown"]);
    expect(await search(app, "q=example-exporter")).toEqual(["TargetDown"]);
    expect(await search(app, "q=example-prod")).toEqual(["KubePodCrashLooping", "TargetDown"]);
  });

  it("takes % and _ in the text literally", async () => {
    const { app } = await inbox();

    expect(await search(app, `q=${encodeURIComponent("_50%")}`)).toEqual(["DiskFull_50%"]);
    expect(await search(app, `q=${encodeURIComponent("%")}`)).toEqual(["DiskFull_50%"]);
    expect(await search(app, "q=Disk_ull")).toEqual([]);
  });

  it("matches labels exactly, every one given", async () => {
    const { app } = await inbox();

    expect(await search(app, "label=namespace%3Dexample-prod")).toEqual([
      "KubePodCrashLooping",
      "TargetDown",
    ]);
    expect(await search(app, "label=namespace%3Dexample-prod&label=severity%3Dcritical")).toEqual([
      "TargetDown",
    ]);
    expect(await search(app, "label=namespace%3Dexample")).toEqual([]);
    // A value may contain "=" itself: only the first one separates.
    expect(await search(app, "label=pod%3Ddb-0%3Dx")).toEqual([]);
    expect(
      await search(app, `label=${encodeURIComponent('query=used{path="C:\\data"}=1')}`),
    ).toEqual(["DiskFull_50%"]);
  });

  it("finds a label's value as it is, with quotes and backslashes, not as JSON writes it", async () => {
    const { app } = await inbox();

    expect(await search(app, `q=${encodeURIComponent('"C:\\data"')}`)).toEqual(["DiskFull_50%"]);
    expect(await search(app, `q=${encodeURIComponent("\\")}`)).toEqual(["DiskFull_50%"]);
    // JSON's own punctuation is no text of any label.
    expect(await search(app, `q=${encodeURIComponent('":"')}`)).toEqual([]);
  });

  it("filters by severity and instance, and combines with the text and status", async () => {
    const { app } = await inbox();

    expect(await search(app, "severity=critical&severity=info")).toEqual([
      "DiskFull_50%",
      "TargetDown",
    ]);
    expect(await search(app, "instance=prod")).toEqual(["DiskFull_50%"]);
    expect(await search(app, "instance=lab&q=example&status=firing")).toEqual([
      "KubePodCrashLooping",
      "TargetDown",
    ]);
    expect(await search(app, "q=example&status=resolved")).toEqual([]);
  });

  it("applies to a channel's list too, and pages through the matches", async () => {
    const { app } = await inbox();

    expect(await titles(app, "/api/instances/lab/channels/ops/occurrences?q=down")).toEqual([
      "TargetDown",
    ]);
    const first = await getJson(app, "/api/occurrences?q=example&limit=1");
    expect(first.body.occurrences).toHaveLength(1);
    const second = await getJson(
      app,
      `/api/occurrences?q=example&limit=1&cursor=${first.body.nextCursor}`,
    );
    expect(second.body.occurrences).toHaveLength(1);
    expect(second.body.nextCursor).toBeNull();
  });

  it("answers 400 for a label without a name or =", async () => {
    const { app } = await inbox();

    expect((await getJson(app, "/api/occurrences?label=namespace")).status).toBe(400);
    expect((await getJson(app, "/api/occurrences?label=%3Dx")).status).toBe(400);
  });

  it("answers 400, not a database error, for a NUL or an invalid instance", async () => {
    const { app } = await inbox();

    for (const query of ["q=%00", "label=x%3D%00", "instance=%00", "instance=Not%20One"]) {
      const response = await getJson(app, `/api/occurrences?${query}`);
      expect(response.status, query).toBe(400);
      expect(JSON.stringify(response.body), query).not.toContain("select");
    }
  });
});
