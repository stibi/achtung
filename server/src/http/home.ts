import { z } from "zod";
import type { ListedAlert } from "../domain/overview.ts";
import type { AlertmanagerAlertList, AlertmanagerOverview, Home } from "../services/home.ts";
import type { Api, Inbox } from "./api-contract.ts";
import {
  errorBody,
  labelSet,
  occurrenceBody,
  severity,
  timestamp,
  toOccurrenceBody,
} from "./api-schemas.ts";

// GET /api/home and the alerts behind each Alertmanager's tile (ADR 0010). Their shapes
// live here, next to the routes that use them; api-schemas.ts explains how a shape change
// reaches the client.

const count = z.int().nonnegative();
const fingerprint = z.string().describe("Alertmanager's fingerprint, an occurrence's sourceKey");

// How the latest read of an Alertmanager's alerts went, the same in both views.
const readFields = {
  instance: z.string(),
  reachable: z.boolean().describe("Whether the latest read of its alerts succeeded"),
  error: z.string().nullable().describe("Why the latest read failed; null when reachable"),
  checkedAt: timestamp
    .nullable()
    .describe("When its alerts were last read successfully; the fields below are from that read"),
};

function toReadFields(
  instance: string,
  error: string | null,
  readAt: Date | undefined,
): { [K in keyof typeof readFields]: z.infer<(typeof readFields)[K]> } {
  return { instance, reachable: error === null, error, checkedAt: readAt?.toISOString() ?? null };
}

const openCountsBody = z
  .object({
    total: count,
    critical: count,
    warning: count,
    info: count,
    other: count.describe("No severity label, or one Achtung doesn't know"),
  })
  .meta({ id: "OpenAlertCounts" });

const missingAlertBody = z
  .object({
    fingerprint,
    title: z.string().describe("The alertname"),
    severity,
    startsAt: timestamp,
  })
  .meta({ id: "MissingAlert" });

const deliveryBody = z
  .object({
    missingInAchtung: z
      .array(missingAlertBody)
      .describe(
        "Notifying in Alertmanager for over 10 minutes, routed to a receiver that delivers to Achtung, but not firing in Achtung. Oldest first",
      ),
    staleInAchtung: z
      .array(occurrenceBody)
      .describe(
        "Firing in Achtung, last notified over 10 minutes before the read, but gone from Alertmanager: a resolve that never arrived. Oldest first",
      ),
  })
  .meta({ id: "Delivery" });

const alertmanagerBody = z
  .object({
    ...readFields,
    open: openCountsBody
      .nullable()
      .describe(
        "Alerts that are notifying (not silenced or inhibited), by severity; null when never read",
      ),
    silenced: count.nullable(),
    inhibited: count.nullable().describe("Inhibited and not silenced"),
    watchdog: z
      .enum(["firing", "absent"])
      .nullable()
      .describe("Whether the Watchdog alert is there, i.e. the alerting pipeline works"),
    delivery: deliveryBody.nullable(),
  })
  .describe("Counts leave out Watchdog and InfoInhibitor, which fire all the time")
  .meta({ id: "AlertmanagerOverview" });

const silenceBody = z
  .object({
    instance: z.string(),
    id: z.string(),
    startsAt: timestamp,
    endsAt: timestamp,
    createdBy: z.string(),
    comment: z.string(),
    matchers: z.array(
      z
        .object({
          name: z.string(),
          value: z.string(),
          isRegex: z.boolean(),
          isEqual: z.boolean().describe("False negates the match (!= or !~)"),
        })
        .meta({ id: "Matcher" }),
    ),
  })
  .meta({ id: "Silence" });

const noisyAlertBody = z
  .object({
    occurrence: occurrenceBody,
    events: count.describe("Its fired, reopened and resent events in the last 24 hours"),
  })
  .meta({ id: "NoisyAlert" });

const homeBody = z
  .object({
    alertmanagers: z
      .array(alertmanagerBody)
      .describe("Every configured Alertmanager, by instance name"),
    silences: z
      .array(silenceBody)
      .describe("Silences active now on every Alertmanager, the soonest to end first"),
    noisiest: z
      .array(noisyAlertBody)
      .describe(
        "Up to 10 alerts with 2 or more events in the last 24 hours, most first, each as its newest occurrence",
      ),
    longestFiring: z
      .array(occurrenceBody)
      .describe("Up to 10 firing occurrences, the earliest start first"),
  })
  .meta({ id: "Home" });

function toAlertmanagerBody({
  instance,
  error,
  last,
}: AlertmanagerOverview): z.infer<typeof alertmanagerBody> {
  return {
    ...toReadFields(instance, error, last?.readAt),
    open: last?.counts.open ?? null,
    silenced: last?.counts.silenced ?? null,
    inhibited: last?.counts.inhibited ?? null,
    watchdog: last?.counts.watchdog ?? null,
    delivery:
      last === null
        ? null
        : {
            missingInAchtung: last.delivery.missingInAchtung.map((alert) => ({
              ...alert,
              startsAt: alert.startsAt.toISOString(),
            })),
            staleInAchtung: last.delivery.staleInAchtung.map(toOccurrenceBody),
          },
  };
}

function toHomeBody(home: Home): z.infer<typeof homeBody> {
  return {
    alertmanagers: home.alertmanagers.map(toAlertmanagerBody),
    silences: home.silences.map((silence) => ({
      ...silence,
      matchers: [...silence.matchers],
      startsAt: silence.startsAt.toISOString(),
      endsAt: silence.endsAt.toISOString(),
    })),
    noisiest: home.noisiest.map(({ occurrence, events }) => ({
      occurrence: toOccurrenceBody(occurrence),
      events,
    })),
    longestFiring: home.longestFiring.map(toOccurrenceBody),
  };
}

const listedAlertBody = z
  .object({
    fingerprint,
    title: z.string().describe("The alertname, else the fingerprint"),
    severity,
    summary: z.string().nullable().describe("The summary annotation, else the description"),
    startsAt: timestamp,
    labels: labelSet,
    annotations: labelSet,
    state: z
      .enum(["active", "silenced", "inhibited"])
      .describe(
        "active: notifying, or not routed yet; silenced: a silence mutes it, inhibited or not; inhibited: only inhibited",
      ),
    silencedUntil: timestamp
      .nullable()
      .describe(
        "When the latest silence muting it ends; null unless silenced, or when Achtung doesn't know that silence yet",
      ),
    occurrenceId: z
      .int()
      .positive()
      .nullable()
      .describe(
        "The occurrence of this firing (same fingerprint and startsAt) on the instance; null when Achtung has none",
      ),
  })
  .meta({ id: "AlertmanagerAlert" });

const alertListBody = z
  .object({
    ...readFields,
    alerts: z
      .array(listedAlertBody)
      .describe(
        "By severity (critical, warning, info, unknown), then the newest start first; empty when never read",
      ),
  })
  .describe(
    "The alerts the tile counts: active ones are open, the others silenced and inhibited. Leaves out Watchdog and InfoInhibitor",
  )
  .meta({ id: "AlertmanagerAlertList" });

function toListedAlertBody(alert: ListedAlert): z.infer<typeof listedAlertBody> {
  return {
    fingerprint: alert.fingerprint,
    title: alert.title,
    severity: alert.severity,
    summary: alert.summary,
    startsAt: alert.startsAt.toISOString(),
    labels: alert.labels,
    annotations: alert.annotations,
    state: alert.state,
    silencedUntil: alert.state === "silenced" ? (alert.silencedUntil?.toISOString() ?? null) : null,
    occurrenceId: alert.occurrenceId,
  };
}

function toAlertListBody({
  instance,
  error,
  last,
}: AlertmanagerAlertList): z.infer<typeof alertListBody> {
  return {
    ...toReadFields(instance, error, last?.readAt),
    alerts: last?.alerts.map(toListedAlertBody) ?? [],
  };
}

export function registerHomeRoutes(api: Api, inbox: Inbox): void {
  api.get(
    "/api/home",
    {
      schema: {
        tags: ["client"],
        operationId: "getHome",
        summary: "Each Alertmanager's state, active silences, and the noisiest and longest alerts",
        description:
          "Counts come from each Alertmanager, read at most every 30 seconds; an unreachable one keeps its last read. " +
          "delivery compares that read with what fires in Achtung, and only reports (ADR 0010).",
        response: { 200: homeBody },
      },
    },
    async () => toHomeBody(await inbox.getHome()),
  );
  api.get(
    "/api/alertmanagers/:instance/alerts",
    {
      schema: {
        tags: ["client"],
        operationId: "listAlertmanagerAlerts",
        summary: "The alerts behind an Alertmanager's tile on Home",
        description:
          "From the same read as /api/home's counts, so they agree: active alerts are its open, the others its silenced and inhibited. " +
          "An unreachable Alertmanager keeps its last read. 404 when the instance has no Alertmanager configured.",
        params: z.object({ instance: z.string() }),
        response: { 200: alertListBody, 404: errorBody },
      },
    },
    async (request, reply) => {
      const list = await inbox.listAlertmanagerAlerts(request.params.instance);
      if (list === null) {
        return reply.code(404).send({ error: "Alertmanager not found" });
      }
      return toAlertListBody(list);
    },
  );
}
