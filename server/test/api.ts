// Shared by the client API tests in test/http/.
import type { FastifyInstance } from "fastify";
import type { IncomingAlert } from "../src/domain/alert.ts";
import {
  type ChannelSlug,
  type InstanceName,
  parseChannelSlug,
  parseInstanceName,
} from "../src/domain/channel.ts";
import type { Services } from "../src/http/app.ts";
import { alertmanagerSource } from "../src/sources/alertmanager/index.ts";
import { loadFixture } from "./fixtures.ts";

function alertsFrom(fixture: "firing" | "resolved"): readonly IncomingAlert[] {
  const result = alertmanagerSource.parse(loadFixture("alertmanager", fixture));
  if (!result.ok) {
    throw new Error(result.error);
  }
  return result.alerts;
}

export const [crashLoop, targetDown] = alertsFrom("firing") as [IncomingAlert, IncomingAlert];
export const [crashLoopResolved] = alertsFrom("resolved") as [IncomingAlert];

/** Ingests through the real service, with a controlled clock so ordering is exact. */
export function deliver(
  services: Services,
  alerts: readonly IncomingAlert[],
  at: string,
  channel = "example-prod",
  instance = "lab",
  receiver: string | null = "achtung-example-prod",
) {
  return services.ingest({
    source: "alertmanager",
    channel: {
      instance: parseInstanceName(instance) as InstanceName,
      slug: parseChannelSlug(channel) as ChannelSlug,
    },
    alerts,
    receiver,
    receivedAt: new Date(at),
  });
}

export async function getJson(app: FastifyInstance, url: string) {
  const response = await app.inject({ method: "GET", url });
  return { status: response.statusCode, body: response.json() };
}

export async function titles(app: FastifyInstance, url: string): Promise<string[]> {
  const { body } = await getJson(app, url);
  return body.occurrences.map((occurrence: { title: string }) => occurrence.title);
}
