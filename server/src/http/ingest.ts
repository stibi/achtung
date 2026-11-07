import type { FastifyInstance } from "fastify";
import { channelSlugRule, parseChannelSlug } from "../domain/channel.ts";
import type { IngestSummary, Notification } from "../services/ingest.ts";
import type { SourceAdapter } from "../sources/source-adapter.ts";

export type Ingest = (notification: Notification) => Promise<IngestSummary>;

/** POST /ingest/{source}/{channel} for every source. Unknown channels are created. */
export function registerIngestRoutes(
  app: FastifyInstance,
  sources: readonly SourceAdapter[],
  ingest: Ingest,
): void {
  for (const source of sources) {
    app.post<{ Params: { channel: string } }>(
      `/ingest/${source.id}/:channel`,
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
