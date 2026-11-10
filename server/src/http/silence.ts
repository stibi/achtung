import type { FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import type { SilenceResult } from "../services/silences.ts";
import type { Api, Inbox } from "./api-contract.ts";
import { errorBody, occurrenceBody, timestamp, toOccurrenceBody } from "./api-schemas.ts";

// From a minute to 30 days: the client offers 1h, 4h, 1d and 1w.
const durationSeconds = z
  .int()
  .min(60)
  .max(30 * 24 * 60 * 60)
  .describe("How long the silence lasts, from now");
const silenceRequest = z.object({ durationSeconds });

const alertsSilenceRequest = z.object({
  fingerprints: z
    .array(z.string().min(1))
    .min(1)
    .max(500)
    .describe("The alerts to silence, each by its fingerprint in this Alertmanager"),
  durationSeconds,
});

const alertsSilenceBody = z
  .object({
    alerts: z.array(
      z.object({
        fingerprint: z.string(),
        silencedUntil: timestamp
          .nullable()
          .describe("When its silence ends; null when it wasn't silenced"),
        error: z.string().nullable().describe("Why it wasn't silenced; null when it was"),
      }),
    ),
  })
  .describe("One entry per fingerprint asked for, in that order")
  .meta({ id: "AlertsSilenced" });

export function registerSilenceRoutes(api: Api, inbox: Inbox): void {
  api.post(
    "/api/occurrences/:id/silence",
    {
      schema: {
        tags: ["client"],
        operationId: "silenceOccurrence",
        summary: "Silence the occurrence's alert on its instance's Alertmanager",
        description:
          "Silences the alert until durationSeconds from now, with an Alertmanager silence that matches every label of the alert exactly, so it also covers a re-fire. " +
          "If the alert already has such a silence, it is changed to end then, sooner or later, instead of another being added (ADR 0015). " +
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
    async (request, reply) =>
      answer(
        await inbox.silenceOccurrence(request.params.id, request.body.durationSeconds),
        request,
        reply,
      ),
  );

  api.delete(
    "/api/occurrences/:id/silence",
    {
      schema: {
        tags: ["client"],
        operationId: "unsilenceOccurrence",
        summary: "End the occurrence's alert's own silences on its instance's Alertmanager",
        description:
          "Ends now every silence that matches exactly this alert's labels, as POST creates them, so the alert notifies again. " +
          "A broader silence, which mutes other alerts too, is left alone: the answer's silencedUntil then still shows it, " +
          "and when only such a silence mutes the alert, nothing is ended and the answer is 409 (ADR 0015). " +
          "Ending an alert that has no silence is not an error. " +
          "409: also when the instance has no Alertmanager configured. 502: Alertmanager was unreachable or refused.",
        params: z.object({ id: z.coerce.number().int().positive() }),
        response: {
          200: occurrenceBody,
          400: errorBody,
          404: errorBody,
          409: errorBody,
          502: errorBody,
        },
      },
    },
    async (request, reply) =>
      answer(await inbox.unsilenceOccurrence(request.params.id), request, reply),
  );

  registerAlertsSilenceRoute(api, inbox);
}

function registerAlertsSilenceRoute(api: Api, inbox: Inbox): void {
  api.post(
    "/api/alertmanagers/:instance/silences",
    {
      schema: {
        tags: ["client"],
        operationId: "silenceAlertmanagerAlerts",
        summary: "Silence several of an Alertmanager's alerts, each exactly",
        description:
          "Silences each alert, found by fingerprint in a fresh read of the instance's Alertmanager, with its own silence matching exactly its labels, " +
          "as POST /api/occurrences/{id}/silence does: an exact silence it already has is changed to the new end (ADR 0015, ADR 0016). " +
          "Alerts not in Achtung can be silenced too. An alert no longer in Alertmanager gets an error and no silence. " +
          "It mutes the alerts for every receiver of that Alertmanager, not only Achtung. " +
          "404: the instance has no Alertmanager configured. 502: Alertmanager was unreachable or refused; some silences may be made, and a retry changes them rather than adding more.",
        params: z.object({ instance: z.string() }),
        body: alertsSilenceRequest,
        response: { 200: alertsSilenceBody, 400: errorBody, 404: errorBody, 502: errorBody },
      },
    },
    async (request, reply) => {
      const { fingerprints, durationSeconds: seconds } = request.body;
      const result = await inbox.silenceAlertmanagerAlerts(
        request.params.instance,
        fingerprints,
        seconds,
      );
      switch (result.kind) {
        case "silenced":
          return {
            alerts: result.alerts.map((alert) => ({
              ...alert,
              silencedUntil: alert.silencedUntil?.toISOString() ?? null,
            })),
          };
        case "not-found":
          return reply.code(404).send({ error: "Alertmanager not found" });
        case "failed":
          request.log.warn({ reason: result.reason }, "Alertmanager did not silence the alerts");
          return reply.code(502).send({ error: result.reason });
      }
    },
  );
}

function answer(result: SilenceResult, request: FastifyRequest, reply: FastifyReply) {
  switch (result.kind) {
    case "silenced":
      return toOccurrenceBody(result.occurrence);
    case "not-found":
      return reply.code(404).send({ error: "Occurrence not found" });
    case "not-silenceable":
      return reply.code(409).send({ error: result.reason });
    case "failed":
      request.log.warn({ reason: result.reason }, "Alertmanager did not change the silence");
      return reply.code(502).send({ error: result.reason });
  }
}
