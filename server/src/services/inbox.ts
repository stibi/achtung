import type { Database } from "../db/client.ts";
import {
  findChannelId,
  findInstancesWithChannel,
  findOccurrence,
  listChannelOverviews,
  listEvents,
  listOccurrences,
  listOtherOccurrences,
} from "../db/queries.ts";
import type { AlertState } from "../domain/alert.ts";
import { type ChannelAddress, resolveChannel } from "../domain/channel.ts";
import type { Occurrence, OccurrenceEvent } from "../domain/occurrence.ts";

/** A place in a channel's list, newest change first. The next page starts after it. */
export interface ListPosition {
  readonly lastEventAt: Date;
  readonly id: number;
}

export interface OccurrenceFilter {
  readonly status: AlertState["status"] | null;
  readonly after: ListPosition | null;
  readonly limit: number;
}

export interface ChannelOverview {
  readonly instance: string;
  readonly slug: string;
  /** Occurrences in this channel that are firing now. */
  readonly firing: number;
  /** Latest event in the channel; null for a channel without occurrences. */
  readonly lastEventAt: Date | null;
}

export interface OccurrencePage {
  readonly occurrences: readonly Occurrence[];
  /** Where the next page starts; null when this is the last page. */
  readonly next: ListPosition | null;
}

export type ChannelOccurrencePage =
  | ({ readonly found: true } & OccurrencePage)
  | { readonly found: false };

export interface OccurrenceDetail {
  readonly occurrence: Occurrence;
  /** Oldest first. */
  readonly events: readonly OccurrenceEvent[];
  /** Earlier and later occurrences of the same alert, newest first. */
  readonly otherOccurrences: readonly Occurrence[];
}

const otherOccurrencesShown = 20;

export function listChannels(db: Database): Promise<ChannelOverview[]> {
  return listChannelOverviews(db);
}

export async function listChannelOccurrences(
  db: Database,
  address: ChannelAddress,
  filter: OccurrenceFilter,
): Promise<ChannelOccurrencePage> {
  const instances =
    address.instance === null ? await findInstancesWithChannel(db, address.slug) : [];
  const channelId = await findChannelId(db, resolveChannel(address, instances));
  if (channelId === null) {
    return { found: false };
  }
  return { found: true, ...(await pageOf(db, channelId, filter)) };
}

/** Every channel's occurrences in one list, in the same order as a channel's. */
export function listAllOccurrences(
  db: Database,
  filter: OccurrenceFilter,
): Promise<OccurrencePage> {
  return pageOf(db, null, filter);
}

async function pageOf(
  db: Database,
  channelId: number | null,
  filter: OccurrenceFilter,
): Promise<OccurrencePage> {
  // One extra row tells whether another page follows, without a count query.
  const rows = await listOccurrences(db, channelId, { ...filter, limit: filter.limit + 1 });
  const page = rows.slice(0, filter.limit);
  const last = page.at(-1);
  const next =
    rows.length > filter.limit && last !== undefined
      ? { lastEventAt: last.lastEventAt, id: last.id }
      : null;
  return { occurrences: page, next };
}

export async function getOccurrence(db: Database, id: number): Promise<OccurrenceDetail | null> {
  const occurrence = await findOccurrence(db, id);
  if (occurrence === null) {
    return null;
  }
  const [events, otherOccurrences] = await Promise.all([
    listEvents(db, id),
    listOtherOccurrences(db, occurrence, otherOccurrencesShown),
  ]);
  return { occurrence, events, otherOccurrences };
}
