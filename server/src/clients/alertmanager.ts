import { z } from "zod";
import type { AlertmanagerAlert } from "../domain/overview.ts";
import type { LabelMatcher, Silence } from "../domain/silence.ts";
import { reasonOf } from "./failure-reason.ts";

// Alertmanager's API v2: https://github.com/prometheus/alertmanager/blob/main/api/v2/openapi.yaml

/** Where one instance's Alertmanager is, and how to authenticate to it. */
export interface AlertmanagerEndpoint {
  /** Base URL, including any route prefix, e.g. http://alertmanager:9093/. */
  readonly url: string;
  readonly basicAuth: { readonly username: string; readonly password: string } | null;
}

export interface NewSilence {
  /** An existing silence's id to change it; Alertmanager may end it and answer a new id. */
  readonly id?: string;
  readonly matchers: readonly LabelMatcher[];
  readonly startsAt: Date;
  readonly endsAt: Date;
  readonly createdBy: string;
  readonly comment: string;
}

/** Alertmanager could not be reached, or it refused the request. */
export class AlertmanagerError extends Error {
  override readonly name = "AlertmanagerError";
  /**
   * The message without anything Alertmanager answered, which can be a proxy's error page
   * naming hosts: safe to show to every client.
   */
  readonly reason: string;

  constructor(message: string, reason = message) {
    super(message);
    this.reason = reason;
  }
}

const timeoutMs = 5000;

const silenceBody = z.object({
  id: z.string(),
  status: z.object({ state: z.enum(["active", "pending", "expired"]) }),
  matchers: z.array(
    z.object({
      name: z.string(),
      value: z.string(),
      isRegex: z.boolean(),
      // Absent before Alertmanager 0.22, which only had equality.
      isEqual: z.boolean().default(true),
    }),
  ),
  startsAt: z.iso.datetime({ offset: true }),
  endsAt: z.iso.datetime({ offset: true }),
  createdBy: z.string(),
  comment: z.string(),
});

/** Every silence that is active or pending; expired ones are dropped. */
export async function listSilences(endpoint: AlertmanagerEndpoint): Promise<Silence[]> {
  const body = await call(endpoint, "GET", "api/v2/silences");
  const parsed = z.array(silenceBody).safeParse(body);
  if (!parsed.success) {
    throw new AlertmanagerError(`unexpected silences response: ${parsed.error.message}`);
  }
  return parsed.data
    .filter((silence) => silence.status.state !== "expired")
    .map((silence) => ({
      id: silence.id,
      matchers: silence.matchers,
      startsAt: new Date(silence.startsAt),
      endsAt: new Date(silence.endsAt),
      createdBy: silence.createdBy,
      comment: silence.comment,
    }));
}

const alertBody = z.object({
  fingerprint: z.string(),
  labels: z.record(z.string(), z.string()),
  annotations: z.record(z.string(), z.string()),
  startsAt: z.iso.datetime({ offset: true }),
  status: z.object({
    state: z.enum(["active", "suppressed", "unprocessed"]),
    silencedBy: z.array(z.string()),
    inhibitedBy: z.array(z.string()),
  }),
  receivers: z.array(z.object({ name: z.string() })),
});

/** Every alert Alertmanager has, in any state: active, suppressed or unprocessed. */
export async function listAlerts(endpoint: AlertmanagerEndpoint): Promise<AlertmanagerAlert[]> {
  const body = await call(endpoint, "GET", "api/v2/alerts");
  const parsed = z.array(alertBody).safeParse(body);
  if (!parsed.success) {
    throw new AlertmanagerError(`unexpected alerts response: ${parsed.error.message}`);
  }
  return parsed.data.map((alert) => ({
    fingerprint: alert.fingerprint,
    labels: alert.labels,
    annotations: alert.annotations,
    startsAt: new Date(alert.startsAt),
    state: alert.status.state,
    silencedBy: alert.status.silencedBy,
    inhibitedBy: alert.status.inhibitedBy,
    receivers: alert.receivers.map((receiver) => receiver.name),
  }));
}

/** Creates the silence and returns its id. */
export async function createSilence(
  endpoint: AlertmanagerEndpoint,
  silence: NewSilence,
): Promise<string> {
  const body = await call(endpoint, "POST", "api/v2/silences", {
    ...silence,
    startsAt: silence.startsAt.toISOString(),
    endsAt: silence.endsAt.toISOString(),
  });
  const parsed = z.object({ silenceID: z.string() }).safeParse(body);
  if (!parsed.success) {
    throw new AlertmanagerError(`unexpected response to a new silence: ${parsed.error.message}`);
  }
  return parsed.data.silenceID;
}

/** Ends the silence now (Alertmanager calls it expiring). */
export async function expireSilence(endpoint: AlertmanagerEndpoint, id: string): Promise<void> {
  await call(endpoint, "DELETE", `api/v2/silence/${encodeURIComponent(id)}`);
}

async function call(
  endpoint: AlertmanagerEndpoint,
  method: "GET" | "POST" | "DELETE",
  path: string,
  body?: unknown,
): Promise<unknown> {
  const base = endpoint.url.endsWith("/") ? endpoint.url : `${endpoint.url}/`;
  const headers: Record<string, string> = { accept: "application/json" };
  if (body !== undefined) {
    headers["content-type"] = "application/json";
  }
  if (endpoint.basicAuth !== null) {
    const { username, password } = endpoint.basicAuth;
    headers["authorization"] = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
  }
  let response: Response;
  let text: string;
  try {
    response = await fetch(new URL(path, base), {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    // Inside the try: a timeout or a dropped connection can also happen while the body is read.
    text = await response.text();
  } catch (error) {
    throw new AlertmanagerError(`Alertmanager is unreachable (${reasonOf(error)})`);
  }
  if (!response.ok) {
    // Alertmanager explains a rejected silence in the body, e.g. "invalid label matcher".
    throw new AlertmanagerError(
      `Alertmanager answered ${response.status}: ${text.trim().slice(0, 500)}`,
      `Alertmanager answered ${response.status}`,
    );
  }
  if (method === "DELETE") {
    return undefined;
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new AlertmanagerError("Alertmanager answered with something that is not JSON");
  }
}
