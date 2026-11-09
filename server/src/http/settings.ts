import { z } from "zod";
import type { Api, Inbox } from "./api-contract.ts";
import { errorBody } from "./api-schemas.ts";

// Settings shared by every client (ADR 0011). There are no users (ADR 0002): anyone who
// can reach the API can change them, as with silences.

const maxNameLength = 200;
const maxNames = 200;

const ignoredAlertNamesBody = z
  .object({
    names: z.array(z.string()).describe("Alert names, sorted"),
  })
  .describe(
    "Alert names the Home views leave out of an Alertmanager's counts, its alert list and its delivery check. " +
      "Matched exactly and case-sensitively against the alertname label. The inbox shows these alerts as usual",
  )
  .meta({ id: "IgnoredAlertNames" });

const ignoredAlertNamesRequest = z.object({
  names: z
    .array(
      z
        .string()
        .trim()
        .min(1)
        .max(maxNameLength)
        .describe("An alertname; surrounding whitespace is trimmed"),
    )
    .max(maxNames)
    .describe("The whole new list; a name given twice is stored once"),
});

export function registerSettingsRoutes(api: Api, inbox: Inbox): void {
  api.get(
    "/api/settings/ignored-alerts",
    {
      schema: {
        tags: ["client"],
        operationId: "getIgnoredAlertNames",
        summary: "The alert names the Home views leave out",
        response: { 200: ignoredAlertNamesBody },
      },
    },
    async () => ({ names: await inbox.getIgnoredAlertNames() }),
  );
  api.put(
    "/api/settings/ignored-alerts",
    {
      schema: {
        tags: ["client"],
        operationId: "setIgnoredAlertNames",
        summary: "Replace the alert names the Home views leave out",
        description:
          "One list shared by every client. It applies to the next request, also to a cached Alertmanager read. " +
          "Watchdog's heart on Home doesn't depend on it. " +
          `400: an empty name, one over ${maxNameLength} characters, or over ${maxNames} names.`,
        body: ignoredAlertNamesRequest,
        response: { 200: ignoredAlertNamesBody, 400: errorBody },
      },
    },
    async (request) => ({ names: await inbox.setIgnoredAlertNames(request.body.names) }),
  );
}
