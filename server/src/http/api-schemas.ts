import { z } from "zod";
import type { Occurrence, OccurrenceEvent } from "../domain/occurrence.ts";
import type { ChannelOverview, OccurrenceDetail } from "../services/inbox.ts";

// The public API's JSON shapes. They validate every response and generate
// api/openapi.yaml, which the macOS client is generated from. Changing a shape changes
// the client contract: ask first (AGENTS.md), then run `pnpm run api:generate`.
// Adding a field is safe for existing clients. Adding an enum value is not: generated
// Swift enums are closed, so regenerate the client in the same change.

const timestamp = z.iso.datetime({ offset: true });
const labelSet = z.record(z.string(), z.string());

export const errorBody = z.object({ error: z.string() }).meta({ id: "Error" });

export const channelBody = z
  .object({
    slug: z.string(),
    firing: z.int().nonnegative().describe("Occurrences in the channel that are firing now"),
    lastEventAt: timestamp.nullable().describe("Latest event in the channel"),
  })
  .meta({ id: "Channel" });

export const occurrenceBody = z
  .object({
    id: z.int().positive(),
    channel: z.string(),
    source: z.string(),
    sourceKey: z.string().describe("Identity of the alert in its source, e.g. a fingerprint"),
    status: z.enum(["firing", "resolved"]),
    severity: z.enum(["critical", "warning", "info", "unknown"]),
    title: z.string(),
    summary: z.string().nullable(),
    labels: labelSet,
    annotations: labelSet,
    links: z.array(z.object({ kind: z.enum(["source", "runbook", "dashboard"]), url: z.string() })),
    startsAt: timestamp,
    endsAt: timestamp.nullable().describe("Set exactly when the status is resolved"),
    firstReceivedAt: timestamp,
    lastReceivedAt: timestamp,
    lastEventAt: timestamp.describe("Last time it fired, resolved or reopened"),
    notificationCount: z.int().positive(),
  })
  .meta({ id: "Occurrence" });

const eventBody = z
  .object({
    id: z.int().positive(),
    kind: z.enum(["fired", "resolved", "reopened"]),
    recordedAt: timestamp,
  })
  .meta({ id: "Event" });

export const occurrenceDetailBody = z
  .object({
    occurrence: occurrenceBody,
    events: z.array(eventBody).describe("Oldest first"),
    otherOccurrences: z
      .array(occurrenceBody)
      .describe("Other occurrences of the same alert, newest first, at most 20"),
  })
  .meta({ id: "OccurrenceDetail" });

export const channelListBody = z
  .object({ channels: z.array(channelBody) })
  .meta({ id: "ChannelList" });

export const occurrencePageBody = z
  .object({
    occurrences: z.array(occurrenceBody),
    nextCursor: z
      .string()
      .nullable()
      .describe("Pass as cursor for the next page; null on the last"),
  })
  .meta({ id: "OccurrencePage" });

export function toChannelBody(channel: ChannelOverview): z.infer<typeof channelBody> {
  return { ...channel, lastEventAt: channel.lastEventAt?.toISOString() ?? null };
}

export function toOccurrenceBody(occurrence: Occurrence): z.infer<typeof occurrenceBody> {
  return {
    ...occurrence,
    links: [...occurrence.links],
    startsAt: occurrence.startsAt.toISOString(),
    endsAt: occurrence.endsAt?.toISOString() ?? null,
    firstReceivedAt: occurrence.firstReceivedAt.toISOString(),
    lastReceivedAt: occurrence.lastReceivedAt.toISOString(),
    lastEventAt: occurrence.lastEventAt.toISOString(),
  };
}

function toEventBody(event: OccurrenceEvent): z.infer<typeof eventBody> {
  return { ...event, recordedAt: event.recordedAt.toISOString() };
}

export function toOccurrenceDetailBody(
  detail: OccurrenceDetail,
): z.infer<typeof occurrenceDetailBody> {
  return {
    occurrence: toOccurrenceBody(detail.occurrence),
    events: detail.events.map(toEventBody),
    otherOccurrences: detail.otherOccurrences.map(toOccurrenceBody),
  };
}
