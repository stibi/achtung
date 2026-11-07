import type { FastifyInstance } from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import { z } from "zod";
import { channelSlugRule, parseChannelSlug } from "../domain/channel.ts";
import type { IngestSummary, Notification } from "../services/ingest.ts";
import type { SourceAdapter } from "../sources/source-adapter.ts";
import { errorBody } from "./api-schemas.ts";

export type Ingest = (notification: Notification) => Promise<IngestSummary>;

const ingestSummary = z
  .object({
    alerts: z.int().nonnegative(),
    new: z.int().nonnegative().describe("Occurrences that fired or reopened"),
    resolved: z.int().nonnegative(),
  })
  .meta({ id: "IngestSummary" });

/** POST /ingest/{source}/{channel} for every source. Unknown channels are created. */
export function registerIngestRoutes(
  app: FastifyInstance,
  sources: readonly SourceAdapter[],
  ingest: Ingest,
): void {
  for (const source of sources) {
    app.withTypeProvider<ZodTypeProvider>().post(
      `/ingest/${source.id}/:channel`,
      {
        schema: {
          tags: ["ingest"],
          operationId: `ingest${source.id[0]?.toUpperCase()}${source.id.slice(1)}`,
          summary: `Webhook for ${source.id}. The body is the source's own payload.`,
          params: z.object({ channel: z.string().describe("Created on first use") }),
          response: { 200: ingestSummary, 400: errorBody, 404: errorBody },
        },
      },
      async (request, reply) => {
        const channel = parseChannelSlug(request.params.channel);
        if (channel === null) {
          return reply.code(404).send({ error: `Channel names must match ${channelSlugRule}` });
        }
        const parsed = source.parse(request.body);
        if (!parsed.ok) {
          request.log.warn(
            { source: source.id, channel, error: parsed.error, body: request.body },
            "rejected invalid payload",
          );
          return reply.code(400).send({ error: parsed.error });
        }
        if (parsed.truncatedAlerts > 0) {
          request.log.warn(
            { source: source.id, channel, truncatedAlerts: parsed.truncatedAlerts },
            "source dropped alerts from the notification",
          );
        }
        return ingest({
          source: source.id,
          channel,
          alerts: parsed.alerts,
          receivedAt: new Date(),
        });
      },
    );
  }
}
