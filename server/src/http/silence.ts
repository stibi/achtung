import { z } from "zod";
import type { Api, Inbox } from "./api-contract.ts";
import { errorBody, occurrenceBody, toOccurrenceBody } from "./api-schemas.ts";

// From a minute to 30 days: the client offers 1h, 4h, 1d and 1w.
const silenceRequest = z.object({
  durationSeconds: z
    .int()
    .min(60)
    .max(30 * 24 * 60 * 60)
    .describe("How long the silence lasts, from now"),
});

export function registerSilenceRoutes(api: Api, inbox: Inbox): void {
  api.post(
    "/api/occurrences/:id/silence",
    {
      schema: {
        tags: ["client"],
        operationId: "silenceOccurrence",
        summary: "Silence the occurrence's alert on its instance's Alertmanager",
        description:
          "Creates an Alertmanager silence that matches every label of the alert exactly, so it also covers a re-fire. " +
          "It mutes the alert for every receiver of that Alertmanager, not only Achtung (ADR 0008). " +
          "409: the instance has no Alertmanager configured. 502: Alertmanager was unreachable or refused the silence.",
        params: z.object({ id: z.coerce.number().int().positive() }),
        body: silenceRequest,
        response: {
          200: occurrenceBody,
          400: errorBody,
          404: errorBody,
          409: errorBody,
          502: errorBody,
        },
      },
    },
    async (request, reply) => {
      const result = await inbox.silenceOccurrence(request.params.id, request.body.durationSeconds);
      switch (result.kind) {
        case "silenced":
          return toOccurrenceBody(result.occurrence);
        case "not-found":
          return reply.code(404).send({ error: "Occurrence not found" });
        case "not-silenceable":
          return reply.code(409).send({ error: result.reason });
        case "failed":
          request.log.warn({ reason: result.reason }, "Alertmanager did not create the silence");
          return reply.code(502).send({ error: result.reason });
      }
    },
  );
}
