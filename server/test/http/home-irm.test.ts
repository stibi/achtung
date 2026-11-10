import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, unreachableUrl } from "../alertmanager-stub.ts";
import { getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";
import { heartbeatMissing, type IrmStub, startIrmStub } from "../irm-stub.ts";

// The IRM heartbeat on each Home tile (ADR 0012), with a stub IRM.

const token = "glsa_irm-s3cret-token";
const integration = "CLAB0001";

/** One clock for the Alertmanager and IRM reads and the services. */
function clock(start: string) {
  let current = new Date(start);
  const now = () => current;
  return {
    now,
    advance: (seconds: number) => {
      current = new Date(current.getTime() + seconds * 1000);
    },
  };
}

async function homeWithIrm(
  irmUrl: string | null,
  {
    integrations = { lab: integration },
    now = clock("2026-10-13T10:00:00Z").now,
    failures = [],
  }: {
    integrations?: Record<string, string>;
    now?: () => Date;
    /** What each failed read of IRM threw, as the log would get it. */
    failures?: string[];
  } = {},
) {
  const lab = await startAlertmanagerStub();
  const prod = await startAlertmanagerStub();
  const { app } = await appWithDatabase({
    alertmanagers: {
      lab: { url: lab.url, basicAuth: null },
      prod: { url: prod.url, basicAuth: null },
    },
    irm: {
      endpoint: irmUrl === null ? null : { url: irmUrl, token },
      integrations,
      options: {
        now,
        onReadError: (integrationId, error) =>
          failures.push(`${integrationId}: ${error.name} ${error.message} ${error.stack}`),
      },
    },
    silences: { now },
    alerts: { now },
    now,
  });
  return {
    irmOf: async (instance = "lab") =>
      (await getJson(app, "/api/home")).body.alertmanagers.find(
        (tile: { instance: string }) => tile.instance === instance,
      ).irm,
  };
}

/** Reads of IRM's alert groups, the requests the stub should get. */
const groupReadsOf = (irm: IrmStub) =>
  irm.requests.filter((request) => request.path === "/oncall/api/v1/alert_groups/");
const groupReads = (irm: IrmStub) => groupReadsOf(irm).length;

describe("GET /api/home: the IRM heartbeat", () => {
  it("is receiving, with the last missed heartbeat, and asks IRM with the raw token", async () => {
    const irm = await startIrmStub();
    irm.groups.push(
      heartbeatMissing(integration, {
        state: "resolved",
        createdAt: "2026-10-13T08:00:00.123456Z",
        resolvedAt: "2026-10-13T08:02:10Z",
      }),
      heartbeatMissing(integration, {
        state: "resolved",
        createdAt: "2026-10-12T08:00:00Z",
        resolvedAt: "2026-10-12T08:02:00Z",
      }),
    );
    const { irmOf } = await homeWithIrm(irm.url);

    expect(await irmOf()).toEqual({
      status: "receiving",
      since: null,
      lastMissedFrom: "2026-10-13T08:00:00.123Z",
      lastMissedTo: "2026-10-13T08:02:10.000Z",
      checkedAt: "2026-10-13T10:00:00.000Z",
      error: null,
    });
    expect(groupReads(irm)).toBe(1);
    const [request] = groupReadsOf(irm);
    expect(request?.path).toBe("/oncall/api/v1/alert_groups/");
    expect(request?.authorization).toBe(token);
    expect(Object.fromEntries(request?.query ?? [])).toEqual({
      integration_id: integration,
      search: "OnCallHeartBeatMissing",
      perpage: "10",
    });
  });

  it("finds the last missed heartbeat behind more than a page of the integration's other alerts", async () => {
    const irm = await startIrmStub();
    for (let hour = 0; hour < 12; hour += 1) {
      irm.groups.push({
        ...heartbeatMissing(integration, {
          state: "resolved",
          createdAt: `2026-10-13T${String(hour).padStart(2, "0")}:30:00Z`,
          resolvedAt: "2026-10-13T09:45:00Z",
        }),
        title: "CnpgVolumeLowDiskSpace ",
      });
    }
    irm.groups.push(
      heartbeatMissing(integration, {
        state: "resolved",
        createdAt: "2026-10-12T08:00:00Z",
        resolvedAt: "2026-10-12T08:02:00Z",
      }),
    );
    const { irmOf } = await homeWithIrm(irm.url);

    expect(await irmOf()).toMatchObject({
      status: "receiving",
      lastMissedFrom: "2026-10-12T08:00:00.000Z",
      lastMissedTo: "2026-10-12T08:02:00.000Z",
    });
  });

  it("is receiving, never missed, when IRM has no missed-heartbeat group", async () => {
    const irm = await startIrmStub();
    irm.groups.push(
      heartbeatMissing("COTHER", { state: "new", createdAt: "2026-10-13T09:00:00Z" }),
    );
    const { irmOf } = await homeWithIrm(irm.url);

    expect(await irmOf()).toEqual({
      status: "receiving",
      since: null,
      lastMissedFrom: null,
      lastMissedTo: null,
      checkedAt: "2026-10-13T10:00:00.000Z",
      error: null,
    });
  });

  it("is missing since IRM opened the group, also once it is acknowledged", async () => {
    const irm = await startIrmStub();
    irm.groups.push(
      heartbeatMissing(integration, { state: "acknowledged", createdAt: "2026-10-13T09:58:00Z" }),
      heartbeatMissing(integration, {
        state: "resolved",
        createdAt: "2026-10-12T08:00:00Z",
        resolvedAt: "2026-10-12T08:02:00Z",
      }),
    );
    const { irmOf } = await homeWithIrm(irm.url);

    expect(await irmOf()).toEqual({
      status: "missing",
      since: "2026-10-13T09:58:00.000Z",
      lastMissedFrom: null,
      lastMissedTo: null,
      checkedAt: "2026-10-13T10:00:00.000Z",
      error: null,
    });
  });

  it("keeps the last heartbeat while IRM fails, with the reason but not IRM's answer", async () => {
    const irm = await startIrmStub();
    irm.groups.push(
      heartbeatMissing(integration, { state: "new", createdAt: "2026-10-13T09:58:00Z" }),
    );
    const time = clock("2026-10-13T10:00:00Z");
    const failures: string[] = [];
    const { irmOf } = await homeWithIrm(irm.url, { now: time.now, failures });
    await irmOf();

    irm.fail({ status: 401, body: `invalid token ${token} for irm.internal.example.com` });
    time.advance(60);
    await irmOf();
    time.advance(59);

    expect(await irmOf()).toEqual({
      status: "missing",
      since: "2026-10-13T09:58:00.000Z",
      lastMissedFrom: null,
      lastMissedTo: null,
      checkedAt: "2026-10-13T10:00:00.000Z",
      error: "Grafana IRM answered 401",
    });
    // A failed read is kept for its minute too: IRM was asked once more, not twice.
    expect(groupReads(irm)).toBe(2);
    expect(failures).toEqual([expect.stringContaining(`${integration}: IrmError`)]);
    expect(failures.join()).not.toContain(token);
    expect(failures.join()).not.toContain("irm.internal");
  });

  it("is unknown when IRM was never read, naming neither its address nor the token", async () => {
    const url = await unreachableUrl();
    const failures: string[] = [];
    const { irmOf } = await homeWithIrm(`${url}/oncall`, { failures });

    const heartbeat = await irmOf();

    expect(heartbeat).toEqual({
      status: "unknown",
      since: null,
      lastMissedFrom: null,
      lastMissedTo: null,
      checkedAt: null,
      error: "Grafana IRM is unreachable (ECONNREFUSED)",
    });
    const logged = failures.join();
    expect(logged).toContain("ECONNREFUSED");
    expect(logged).not.toContain(new URL(url).hostname);
    expect(logged).not.toContain(token);
  });

  it("reports an answer it can't read as an error", async () => {
    const irm = await startIrmStub();
    irm.groups.push({
      ...heartbeatMissing(integration, { state: "new", createdAt: "2026-10-13T09:58:00Z" }),
      state: "escalating" as "new",
    });
    const { irmOf } = await homeWithIrm(irm.url);

    expect(await irmOf()).toMatchObject({
      status: "unknown",
      error: expect.stringContaining("unexpected alert groups response from Grafana IRM"),
    });
  });

  it("asks IRM once a minute per integration, one read at a time", async () => {
    const irm = await startIrmStub();
    const time = clock("2026-10-13T10:00:00Z");
    const { irmOf } = await homeWithIrm(irm.url, {
      integrations: { lab: integration, prod: integration },
      now: time.now,
    });

    await Promise.all([irmOf("lab"), irmOf("prod")]);
    expect(groupReads(irm)).toBe(1);

    irm.groups.push(
      heartbeatMissing(integration, { state: "new", createdAt: "2026-10-13T10:00:30Z" }),
    );
    time.advance(59);
    expect((await irmOf("prod")).status).toBe("receiving");
    expect(groupReads(irm)).toBe(1);

    time.advance(1);
    expect(await irmOf("prod")).toMatchObject({
      status: "missing",
      checkedAt: "2026-10-13T10:01:00.000Z",
    });
    expect(groupReads(irm)).toBe(2);
  });

  it("is null for an Alertmanager without an IRM integration", async () => {
    const irm = await startIrmStub();
    const { irmOf } = await homeWithIrm(irm.url);

    expect(await irmOf("prod")).toBeNull();
  });

  it("is null when IRM isn't configured, also for an Alertmanager with an integration", async () => {
    const { irmOf } = await homeWithIrm(null);

    expect(await irmOf("lab")).toBeNull();
  });
});
