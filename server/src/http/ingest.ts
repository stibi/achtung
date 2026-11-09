import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import { z } from "zod";
import {
  channelSlugRule,
  type InstanceName,
  parseChannelSlug,
  parseInstanceName,
} from "../domain/channel.ts";
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

const instanceParam = z
  .string()
  .describe("The sending system, e.g. one cluster; created on first use");
const channelParam = z.string().describe("Created on first use");

/**
 * POST /ingest/{source}/{instance}/{channel} for every source, plus the older
 * /ingest/{source}/{channel} without an instance (ADR 0006). Unknown channels are created.
 */
export function registerIngestRoutes(
  app: FastifyInstance,
  sources: readonly SourceAdapter[],
  ingest: Ingest,
): void {
  const api = app.withTypeProvider<ZodTypeProvider>();
  for (const source of sources) {
    const name = `${source.id[0]?.toUpperCase()}${source.id.slice(1)}`;
    const response = { 200: ingestSummary, 400: errorBody, 404: errorBody };
    api.post(
      `/ingest/${source.id}/:instance/:channel`,
      {
        schema: {
          tags: ["ingest"],
          operationId: `ingest${name}`,
          summary: `Webhook for ${source.id}. The body is the source's own payload.`,
          params: z.object({ instance: instanceParam, channel: channelParam }),
          response,
        },
      },
      async (request, reply) => {
        const instance = parseInstanceName(request.params.instance);
        if (instance === null) {
          return reply.code(404).send({ error: `Instance names must match ${channelSlugRule}` });
        }
        return receive(source, ingest, { instance, name: request.params.channel }, request, reply);
      },
    );
    api.post(
      `/ingest/${source.id}/:channel`,
      {
        schema: {
          tags: ["ingest"],
          operationId: `ingest${name}WithoutInstance`,
          summary: `Webhook for ${source.id}, without an instance. Deprecated: use the URL with one.`,
          description:
            "A name one named instance has resolves to its channel; otherwise the default instance's channel is used, created if needed.",
          deprecated: true,
          params: z.object({ channel: channelParam }),
          response,
        },
      },
      (request, reply) =>
        receive(source, ingest, { instance: null, name: request.params.channel }, request, reply),
    );
  }
}

async function receive(
  source: SourceAdapter,
  ingest: Ingest,
  target: { readonly instance: InstanceName | null; readonly name: string },
  request: FastifyRequest,
  reply: FastifyReply,
) {
  const slug = parseChannelSlug(target.name);
  if (slug === null) {
    return reply.code(404).send({ error: `Channel names must match ${channelSlugRule}` });
  }
  const where = { source: source.id, instance: target.instance, channel: slug };
  const parsed = source.parse(request.body);
  if (!parsed.ok) {
    request.log.warn(
      { ...where, error: parsed.error, body: request.body },
      "rejected invalid payload",
    );
    return reply.code(400).send({ error: parsed.error });
  }
  if (parsed.truncatedAlerts > 0) {
    request.log.warn(
      { ...where, truncatedAlerts: parsed.truncatedAlerts },
      "source dropped alerts from the notification",
    );
  }
  return ingest({
    source: source.id,
    channel: { instance: target.instance, slug },
    alerts: parsed.alerts,
    receiver: parsed.receiver,
    receivedAt: new Date(),
  });
}
