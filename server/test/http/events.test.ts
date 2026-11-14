import { get } from "node:http";
import { connect } from "node:net";
import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { startAlertmanagerStub, stubAlert } from "../alertmanager-stub.ts";
import { crashLoop, deliver, targetDown } from "../api.ts";
import { appWithDatabase } from "../app.ts";

// The change stream: Server-Sent Events telling a client what to re-read (ADR 0019).

/** Opens /api/events on a listening app; `next` reads up to the next event or comment. */
async function openStream(app: FastifyInstance) {
  const address = await app.listen({ host: "127.0.0.1", port: 0 });
  const controller = new AbortController();
  const response = await fetch(`${address}/api/events`, { signal: controller.signal });
  const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
  let buffered = "";
  const next = async (): Promise<string> => {
    while (!buffered.includes("\n\n")) {
      const { value, done } = await reader.read();
      if (done) {
        return "(ended)";
      }
      buffered += value;
    }
    const end = buffered.indexOf("\n\n");
    const block = buffered.slice(0, end);
    buffered = buffered.slice(end + 2);
    return block;
  };
  return { response, next, close: () => controller.abort() };
}

/** Status and body of a GET on its own connection, which a closing app need not wait for. */
const getOnce = (url: string) =>
  new Promise<{ status: number; body: string }>((resolve, reject) => {
    get(url, { agent: false }, (response) => {
      if (response.statusCode === 200) {
        response.destroy();
        resolve({ status: 200, body: "" });
        return;
      }
      let body = "";
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => resolve({ status: response.statusCode ?? 0, body }));
    }).on("error", reject);
  });

/** A client that opens a stream and never reads it, so the server's writes back up. */
async function stalledClient(app: FastifyInstance) {
  const { port } = app.server.address() as { port: number };
  const socket = connect(port, "127.0.0.1");
  await new Promise((resolve) => socket.once("connect", resolve));
  socket.write("GET /api/events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
  socket.pause();
  return socket;
}

describe("GET /api/events", () => {
  it("opens with ready, then tells what changed as it happens", async () => {
    const { app, services } = await appWithDatabase();
    const stream = await openStream(app);

    expect(stream.response.headers.get("content-type")).toBe("text/event-stream; charset=utf-8");
    expect(await stream.next()).toBe("retry: 5000\nevent: ready\ndata: {}");

    await deliver(services, [crashLoop], "2026-10-13T08:30:00Z");
    expect(await stream.next()).toBe('event: changed\ndata: {"kind":"occurrences"}');

    await app.inject({
      method: "PUT",
      url: "/api/settings/ignored-alerts",
      body: { names: ["Watchdog"] },
    });
    expect(await stream.next()).toBe('event: changed\ndata: {"kind":"settings"}');
    stream.close();
  });

  it("tells about silences set or ended through Achtung, even one that failed", async () => {
    const stub = await startAlertmanagerStub();
    stub.alerts.push(stubAlert("fp-cpu", { alertname: "CPUThrottling", severity: "warning" }));
    const { app } = await appWithDatabase({
      alertmanagers: { lab: { url: stub.url, basicAuth: null } },
    });
    const stream = await openStream(app);
    await stream.next();

    const silence = () =>
      app.inject({
        method: "POST",
        url: "/api/alertmanagers/lab/silences",
        body: { fingerprints: ["fp-cpu"], durationSeconds: 3600 },
      });
    expect((await silence()).statusCode).toBe(200);
    expect(await stream.next()).toBe('event: changed\ndata: {"kind":"silences"}');

    stub.fail(500, "boom");
    expect((await silence()).statusCode).toBe(502);
    expect(await stream.next()).toBe('event: changed\ndata: {"kind":"silences"}');
    stream.close();
  });

  it("tells about occurrences the reconciler resolved", async () => {
    const lab = await startAlertmanagerStub();
    lab.alerts.push(
      stubAlert(crashLoop.sourceKey, crashLoop.labels, {
        startsAt: crashLoop.startsAt.toISOString(),
      }),
    );
    let now = new Date("2026-10-13T09:00:00Z");
    const clock = () => now;
    const { app, services, reconciler } = await appWithDatabase({
      alertmanagers: { lab: { url: lab.url, basicAuth: null } },
      silences: { now: clock },
      alerts: { now: clock },
      now: clock,
    });
    await deliver(services, [crashLoop, targetDown], "2026-10-13T09:00:00Z");
    const stream = await openStream(app);
    await stream.next();

    for (const at of ["2026-10-13T10:00:00Z", "2026-10-13T10:04:00Z"]) {
      now = new Date(at);
      expect((await reconciler.run()).resolved).toEqual([]);
    }
    now = new Date("2026-10-13T10:05:00Z");
    expect((await reconciler.run()).resolved).toHaveLength(1);

    // Only the run that resolved something told about it.
    expect(await stream.next()).toBe('event: changed\ndata: {"kind":"occurrences"}');
    services.changes.publish("settings");
    expect(await stream.next()).toBe('event: changed\ndata: {"kind":"settings"}');
    stream.close();
  });

  it("keeps an idle stream open with comments", async () => {
    const { app } = await appWithDatabase({ events: { keepaliveMs: 20 } });
    const stream = await openStream(app);
    await stream.next();

    expect(await stream.next()).toBe(": keepalive");
    stream.close();
  });

  it("refuses a stream over the limit, and frees the slot when a client leaves", async () => {
    const { app } = await appWithDatabase({ events: { maxStreams: 1 } });
    const first = await openStream(app);
    await first.next();
    const address = `http://127.0.0.1:${(app.server.address() as { port: number }).port}`;

    const refused = await getOnce(`${address}/api/events`);
    expect(refused.status).toBe(503);
    expect(JSON.parse(refused.body)).toEqual({ error: "Too many event streams are open" });

    first.close();
    await expect.poll(async () => (await getOnce(`${address}/api/events`)).status).toBe(200);
  });

  it("ends its streams when the server closes", async () => {
    const { app } = await appWithDatabase();
    const stream = await openStream(app);
    await stream.next();

    await app.close();

    expect(await stream.next()).toBe("(ended)");
  });

  it("drops a client that stops reading, and frees its slot", async () => {
    const { app, services } = await appWithDatabase({ events: { maxStreams: 1 } });
    const address = await app.listen({ host: "127.0.0.1", port: 0 });
    const stalled = await stalledClient(app);
    await expect.poll(async () => (await getOnce(`${address}/api/events`)).status).toBe(503);

    for (let i = 0; i < 20_000; i++) {
      services.changes.publish("occurrences");
    }

    await expect.poll(async () => (await getOnce(`${address}/api/events`)).status).toBe(200);
    stalled.destroy();
  });

  it("closes without waiting for a client that stopped reading, while changes go on", async () => {
    const { app, services } = await appWithDatabase({ events: { maxStreams: 1 } });
    const address = await app.listen({ host: "127.0.0.1", port: 0 });
    const stalled = await stalledClient(app);
    await expect.poll(async () => (await getOnce(`${address}/api/events`)).status).toBe(503);
    for (let i = 0; i < 20_000; i++) {
      services.changes.publish("occurrences");
    }

    let closed = false;
    const closing = app.close().then(() => {
      closed = true;
    });
    // An ingest still in flight publishes while the server closes.
    const publishing = () => {
      if (!closed) {
        services.changes.publish("occurrences");
        setImmediate(publishing);
      }
    };
    publishing();
    await closing;
    stalled.destroy();
  });
});
