import { z } from "zod";
import { heartbeatMissingTitle, type IrmAlertGroup } from "../domain/irm-heartbeat.ts";
import { reasonOf } from "./failure-reason.ts";

// Grafana IRM's (OnCall's) public API: https://grafana.com/docs/oncall/latest/oncall-api-reference/

/** Where Grafana IRM's API is, and the token for it. */
export interface IrmEndpoint {
  /** Base URL, e.g. https://oncall-prod-eu-west-0.grafana.net/oncall. */
  readonly url: string;
  /** Sent as is in the Authorization header, without "Bearer". */
  readonly token: string;
}

/**
 * Grafana IRM could not be reached, or it refused the request. Its message names neither
 * the URL nor the token nor what IRM answered, so it is safe to log and to show.
 */
export class IrmError extends Error {
  override readonly name = "IrmError";
}

const timeoutMs = 5000;
// More than one: IRM's search matches every title that contains the name.
const groupsRead = 10;

const alertGroupsBody = z.object({
  results: z.array(
    z.object({
      integration_id: z.string(),
      title: z.string(),
      state: z.enum(["new", "acknowledged", "resolved", "silenced"]),
      created_at: z.iso.datetime({ offset: true }),
      resolved_at: z.iso.datetime({ offset: true }).nullable(),
    }),
  ),
});

/** The integration's latest alert groups for a missed heartbeat, newest first. */
export async function listHeartbeatMissingGroups(
  endpoint: IrmEndpoint,
  integrationId: string,
): Promise<IrmAlertGroup[]> {
  const base = endpoint.url.endsWith("/") ? endpoint.url : `${endpoint.url}/`;
  const url = new URL("api/v1/alert_groups/", base);
  url.search = new URLSearchParams({
    integration_id: integrationId,
    // IRM ignores `name`; `search` is what narrows the groups to the title (checked
    // against the real IRM).
    search: heartbeatMissingTitle,
    perpage: String(groupsRead),
  }).toString();
  let response: Response;
  let text: string;
  try {
    response = await fetch(url, {
      headers: { accept: "application/json", authorization: endpoint.token },
      signal: AbortSignal.timeout(timeoutMs),
    });
    // Inside the try: a timeout or a dropped connection can also happen while the body is read.
    text = await response.text();
  } catch (error) {
    throw new IrmError(`Grafana IRM is unreachable (${reasonOf(error)})`);
  }
  if (!response.ok) {
    throw new IrmError(`Grafana IRM answered ${response.status}`);
  }
  const parsed = alertGroupsBody.safeParse(jsonOf(text));
  if (!parsed.success) {
    throw new IrmError(
      `unexpected alert groups response from Grafana IRM: ${parsed.error.message}`,
    );
  }
  return parsed.data.results.map((group) => ({
    integrationId: group.integration_id,
    title: group.title,
    state: group.state,
    createdAt: new Date(group.created_at),
    resolvedAt: group.resolved_at === null ? null : new Date(group.resolved_at),
  }));
}

function jsonOf(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new IrmError("Grafana IRM answered with something that is not JSON");
  }
}
