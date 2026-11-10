import type {
  FastifyBaseLogger,
  FastifyInstance,
  RawReplyDefaultExpression,
  RawRequestDefaultExpression,
  RawServerDefault,
} from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import type { ChannelAddress } from "../domain/channel.ts";
import type { AlertmanagerSilenceResult } from "../services/alertmanager-silences.ts";
import type { AlertmanagerAlertList, Home } from "../services/home.ts";
import type {
  ChannelOccurrencePage,
  ChannelOverview,
  OccurrenceDetail,
  OccurrenceFilter,
  OccurrencePage,
} from "../services/inbox.ts";
import type { SilenceResult } from "../services/silences.ts";

/** The inbox's use cases, as the client API needs them. */
export interface Inbox {
  listChannels(): Promise<ChannelOverview[]>;
  listChannelOccurrences(
    channel: ChannelAddress,
    filter: OccurrenceFilter,
  ): Promise<ChannelOccurrencePage>;
  listOccurrences(filter: OccurrenceFilter): Promise<OccurrencePage>;
  getOccurrence(id: number): Promise<OccurrenceDetail | null>;
  silenceOccurrence(id: number, durationSeconds: number): Promise<SilenceResult>;
  unsilenceOccurrence(id: number): Promise<SilenceResult>;
  silenceAlertmanagerAlerts(
    instance: string,
    fingerprints: readonly string[],
    durationSeconds: number,
  ): Promise<AlertmanagerSilenceResult>;
  getHome(): Promise<Home>;
  /** The alerts behind an Alertmanager's tile; null when the instance has none. */
  listAlertmanagerAlerts(instance: string): Promise<AlertmanagerAlertList | null>;
  /** The alert names the Home views leave out, sorted (ADR 0011). */
  getIgnoredAlertNames(): Promise<string[]>;
  /** Replaces them with `names` and returns them as stored, sorted. */
  setIgnoredAlertNames(names: readonly string[]): Promise<string[]>;
}

/** The app with Zod schemas typing each route's request and reply. */
export type Api = FastifyInstance<
  RawServerDefault,
  RawRequestDefaultExpression,
  RawReplyDefaultExpression,
  FastifyBaseLogger,
  ZodTypeProvider
>;
