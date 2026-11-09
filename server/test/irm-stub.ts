import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { onTestFinished } from "vitest";

/** An alert group as Grafana IRM's API returns it (GET /api/v1/alert_groups/). */
export interface StubAlertGroup {
  id: string;
  integration_id: string;
  title: string;
  state: "new" | "acknowledged" | "resolved" | "silenced";
  created_at: string;
  resolved_at: string | null;
  acknowledged_at: string | null;
}

interface StubRequest {
  readonly path: string;
  readonly query: URLSearchParams;
  readonly authorization: string | undefined;
}

/**
 * A stand-in for Grafana IRM's alert groups API under /oncall, like the real base URL, so
 * tests never reach the real one. It lists the groups a test puts in `groups`, newest
 * first, filtered like IRM: by integration, and by a name the title contains.
 */
export interface IrmStub {
  /** The base URL, with the /oncall prefix. */
  readonly url: string;
  readonly requests: StubRequest[];
  readonly groups: StubAlertGroup[];
  /** Answer every request with this status and body instead; null answers again. */
  fail(failure: { status: number; body: string } | null): void;
}

export async function startIrmStub(): Promise<IrmStub> {
  const requests: StubRequest[] = [];
  const groups: StubAlertGroup[] = [];
  let failure: { status: number; body: string } | null = null;

  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://irm");
    requests.push({
      path: url.pathname,
      query: url.searchParams,
      authorization: request.headers.authorization,
    });
    if (failure !== null) {
      response.writeHead(failure.status, { "content-type": "text/plain" }).end(failure.body);
      return;
    }
    if (request.method !== "GET" || url.pathname !== "/oncall/api/v1/alert_groups/") {
      response.writeHead(404).end("not found");
      return;
    }
    const name = url.searchParams.get("name") ?? "";
    const results = groups
      .filter((group) => group.integration_id === url.searchParams.get("integration_id"))
      .filter((group) => group.title.includes(name))
      .slice(0, Number(url.searchParams.get("perpage") ?? "50"));
    response
      .writeHead(200, { "content-type": "application/json" })
      .end(JSON.stringify({ next: null, results }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}/oncall`,
    requests,
    groups,
    fail: (next) => {
      failure = next;
    },
  };
}

/** A missed-heartbeat group of the integration, as IRM titles it (with its trailing space). */
export function heartbeatMissing(
  integrationId: string,
  {
    state,
    createdAt,
    resolvedAt = null,
  }: { state: StubAlertGroup["state"]; createdAt: string; resolvedAt?: string | null },
): StubAlertGroup {
  return {
    id: `I${integrationId}${createdAt}`,
    integration_id: integrationId,
    title: "OnCallHeartBeatMissing ",
    state,
    created_at: createdAt,
    resolved_at: resolvedAt,
    acknowledged_at: null,
  };
}
