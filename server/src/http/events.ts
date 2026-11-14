import type { ServerResponse } from "node:http";
import { z } from "zod";
import type { ChangeKind, Changes } from "../services/changes.ts";
import type { Api } from "./api-contract.ts";
import { errorBody } from "./api-schemas.ts";

// The change stream (ADR 0019): Server-Sent Events telling a client what to re-read now,
// instead of on its next poll. It carries no data of its own; the client reads that through
// the API as before, and keeps polling, slower, as the fallback.

export interface EventStreamOptions {
  /** How often a comment line keeps an idle stream open through proxies. */
  readonly keepaliveMs?: number;
  /** Streams open at once; one more is refused with 503. */
  readonly maxStreams?: number;
}

/** Written but not yet taken by the client; past it, the client is dropped. */
const maxBufferedBytes = 64 * 1024;

/** How long a client waits before reconnecting after the stream broke (the SSE `retry`). */
const retryMs = 5000;

const changedData = z
  .object({ kind: z.enum(["occurrences", "silences", "settings"]) })
  .describe("What changed")
  .meta({ id: "ChangeEvent" });

const description = [
  "A `text/event-stream` (Server-Sent Events) that stays open. Events:",
  "",
  "- `ready`: sent once the stream is open. Re-read everything: changes made while the client wasn't connected were not sent.",
  '- `changed`: data `{"kind": "occurrences" | "silences" | "settings"}`. Re-read that part: occurrences (a notification arrived, or one resolved as vanished), silences set or ended through Achtung, or the shared settings.',
  "",
  "A comment line keeps the stream open every so often. Silences changed in Alertmanager itself are not announced, so clients still poll, slower, as long as the stream is open. 503: too many streams are open.",
].join("\n");

export function registerEventRoutes(
  api: Api,
  changes: Changes,
  { keepaliveMs = 20_000, maxStreams = 100 }: EventStreamOptions = {},
): void {
  // Each open stream, with what stops it: its keepalive and its subscription.
  const open = new Map<ServerResponse, () => void>();
  const stop = (stream: ServerResponse) => {
    open.get(stream)?.();
    open.delete(stream);
  };
  // It carries no data, so nothing buffered is lost; the client reconnects and re-reads.
  const drop = (stream: ServerResponse) => {
    stop(stream);
    stream.destroy();
  };
  // Close ends the open streams, or it would wait for clients that never hang up: cleanly,
  // and with their connections, which kept alive would hold it open too. A client that
  // doesn't take the end within a second is dropped.
  api.addHook("preClose", async () => {
    for (const stream of [...open.keys()]) {
      stop(stream);
      stream.end(() => stream.destroy());
      setTimeout(() => stream.destroy(), 1000).unref();
    }
  });

  api.get(
    "/api/events",
    {
      schema: {
        tags: ["client"],
        operationId: "streamChanges",
        summary: "What changed, as it happens",
        description,
        response: {
          200: {
            description: "The event stream",
            content: { "text/event-stream": { schema: changedData } },
          },
          503: errorBody,
        },
      },
    },
    async (_request, reply) => {
      if (open.size >= maxStreams) {
        reply.code(503);
        return { error: "Too many event streams are open" };
      }
      reply.hijack();
      const stream = reply.raw;
      stream.writeHead(200, {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache, no-transform",
        // nginx-style proxies otherwise buffer the stream.
        "x-accel-buffering": "no",
      });
      // A client that stopped reading is dropped rather than buffered for without end.
      const send = (text: string) => {
        if (stream.writableLength > maxBufferedBytes) {
          drop(stream);
        } else if (!stream.destroyed) {
          stream.write(text);
        }
      };
      send(`retry: ${retryMs}\nevent: ready\ndata: {}\n\n`);
      const unsubscribe = changes.subscribe((kind: ChangeKind) => {
        send(`event: changed\ndata: ${JSON.stringify({ kind })}\n\n`);
      });
      const keepalive = setInterval(() => send(": keepalive\n\n"), keepaliveMs);
      open.set(stream, () => {
        clearInterval(keepalive);
        unsubscribe();
      });
      // The client hung up, or the stream was dropped.
      stream.on("close", () => drop(stream));
      // Hijacked: Fastify sends nothing more.
      return undefined;
    },
  );
}
