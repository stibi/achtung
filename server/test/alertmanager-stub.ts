import { createServer, type IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { onTestFinished } from "vitest";

/** A silence as Alertmanager's API v2 returns it. */
interface StubSilence {
  id: string;
  status: { state: "active" | "pending" | "expired" };
  matchers: { name: string; value: string; isRegex: boolean; isEqual?: boolean }[];
  startsAt: string;
  endsAt: string;
  createdBy: string;
  comment: string;
}

/** An alert as Alertmanager's API v2 returns it (GET /api/v2/alerts), the fields Achtung reads. */
export interface StubAlert {
  fingerprint: string;
  labels: Record<string, string>;
  annotations: Record<string, string>;
  startsAt: string;
  endsAt: string;
  updatedAt: string;
  generatorURL: string;
  status: {
    state: "active" | "suppressed" | "unprocessed";
    silencedBy: string[];
    inhibitedBy: string[];
    mutedBy: string[];
  };
  receivers: { name: string }[];
}

interface StubRequest {
  readonly method: string;
  readonly path: string;
  readonly authorization: string | undefined;
  readonly body: unknown;
}

/**
 * A stand-in for Alertmanager's silences and alerts API, so tests never reach a real one.
 * It keeps the silences it creates and lists them back, and lists the alerts a test puts
 * in `alerts`.
 */
export interface AlertmanagerStub {
  readonly url: string;
  readonly requests: StubRequest[];
  readonly silences: StubSilence[];
  readonly alerts: StubAlert[];
  /** Answer every request with this status and body instead. */
  fail(status: number, body: string): void;
  /** Answer only reads (of silences and alerts) with this status and body; null answers again. */
  failReads(status: number | null, body?: string): void;
  /**
   * The next list of silences is taken when the request arrives but sent only once
   * `release` is called: a read that is slower than a write after it.
   */
  holdNextRead(): { arrived: Promise<void>; release: () => void };
  /** Drop the connection in the middle of every response body. */
  breakBodies(): void;
}

export async function startAlertmanagerStub(): Promise<AlertmanagerStub> {
  const requests: StubRequest[] = [];
  const silences: StubSilence[] = [];
  const alerts: StubAlert[] = [];
  let failure: { status: number; body: string } | null = null;
  let held: { arrived: () => void; released: Promise<void> } | null = null;
  let broken = false;
  let readFailure: { status: number; body: string } | null = null;
  const failureFor = (method: string | undefined) =>
    failure ?? (method === "GET" ? readFailure : null);

  async function answer(route: string, body: unknown, response: Response) {
    switch (route) {
      case "GET /api/v2/silences": {
        const hold = held;
        held = null;
        await list(response, JSON.stringify(silences), hold);
        break;
      }
      case "GET /api/v2/alerts":
        sendJson(response, alerts);
        break;
      case "POST /api/v2/silences": {
        const id = `silence-${silences.length + 1}`;
        silences.push({
          ...(body as Omit<StubSilence, "id" | "status">),
          id,
          status: { state: "active" },
        });
        sendJson(response, { silenceID: id });
        break;
      }
      default:
        response.writeHead(404).end("not found");
    }
  }

  const server = createServer(async (request, response) => {
    const body = await readBody(request);
    requests.push(recordOf(request, body));
    const failed = failureFor(request.method);
    if (broken) {
      breakBody(response);
    } else if (failed !== null) {
      response.writeHead(failed.status, { "content-type": "text/plain" }).end(failed.body);
    } else {
      await answer(`${request.method} ${request.url}`, body, response);
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    silences,
    alerts,
    fail: (status, text) => {
      failure = { status, body: text };
    },
    failReads: (status, text = "") => {
      readFailure = status === null ? null : { status, body: text };
    },
    holdNextRead: () => {
      let release = () => {};
      let arrived = () => {};
      const arrival = new Promise<void>((resolve) => {
        arrived = resolve;
      });
      const released = new Promise<void>((resolve) => {
        release = resolve;
      });
      held = { arrived, released };
      return { arrived: arrival, release };
    },
    breakBodies: () => {
      broken = true;
    },
  };
}

type Response = Parameters<Parameters<typeof createServer>[1] & {}>[1];

function sendJson(response: Response, body: unknown) {
  response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
}

// Headers first, so the client is reading the body when the connection drops.
function breakBody(response: Response) {
  response.writeHead(200, { "content-type": "application/json" });
  response.flushHeaders();
  response.write('[{"id":');
  setTimeout(() => response.socket?.destroy(), 50);
}

/** Sends the silences as they were when the request arrived, after a hold if any. */
async function list(
  response: Response,
  listed: string,
  hold: { arrived: () => void; released: Promise<void> } | null,
) {
  if (hold !== null) {
    hold.arrived();
    await hold.released;
  }
  response.writeHead(200, { "content-type": "application/json" }).end(listed);
}

function recordOf(request: IncomingMessage, body: unknown): StubRequest {
  return {
    method: request.method ?? "",
    path: request.url ?? "",
    authorization: request.headers.authorization,
    body,
  };
}

async function readBody(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(chunk as Buffer);
  }
  const text = Buffer.concat(chunks).toString();
  return text === "" ? undefined : (JSON.parse(text) as unknown);
}

/** An address nothing listens on: the stub's port after it has closed. */
export async function unreachableUrl(): Promise<string> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return `http://127.0.0.1:${port}`;
}

/** An alert for the stub's `alerts`: active, routed to `receivers`, started an hour before 10:00. */
export function stubAlert(
  fingerprint: string,
  labels: Record<string, string>,
  {
    state = "active",
    silencedBy = [],
    inhibitedBy = [],
    receivers = ["achtung-example-prod"],
    startsAt = "2026-10-13T09:00:00Z",
  }: {
    state?: StubAlert["status"]["state"];
    silencedBy?: string[];
    inhibitedBy?: string[];
    receivers?: string[];
    startsAt?: string;
  } = {},
): StubAlert {
  return {
    fingerprint,
    labels,
    annotations: {},
    startsAt,
    endsAt: "2026-10-13T12:00:00Z",
    updatedAt: startsAt,
    generatorURL: "",
    status: { state, silencedBy, inhibitedBy, mutedBy: [] },
    receivers: receivers.map((name) => ({ name })),
  };
}
