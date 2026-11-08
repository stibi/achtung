import { z } from "zod";
import type { LabelMatcher, Silence } from "../domain/silence.ts";

// Alertmanager's API v2: https://github.com/prometheus/alertmanager/blob/main/api/v2/openapi.yaml

/** Where one instance's Alertmanager is, and how to authenticate to it. */
export interface AlertmanagerEndpoint {
  /** Base URL, including any route prefix, e.g. http://alertmanager:9093/. */
  readonly url: string;
  readonly basicAuth: { readonly username: string; readonly password: string } | null;
}

export interface NewSilence {
  readonly matchers: readonly LabelMatcher[];
  readonly startsAt: Date;
  readonly endsAt: Date;
  readonly createdBy: string;
  readonly comment: string;
}

/** Alertmanager could not be reached, or it refused the request. */
export class AlertmanagerError extends Error {
  override readonly name = "AlertmanagerError";
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

async function call(
  endpoint: AlertmanagerEndpoint,
  method: "GET" | "POST",
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
    );
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new AlertmanagerError("Alertmanager answered with something that is not JSON");
  }
}

// Only a code or a name, never the error's message: fetch's messages can quote the URL.
function reasonOf(error: unknown): string {
  const cause = (error as { cause?: { code?: unknown } }).cause;
  if (typeof cause?.code === "string") {
    return cause.code;
  }
  return error instanceof Error ? error.name : "unknown error";
}
