import type {
  FastifyBaseLogger,
  FastifyInstance,
  RawReplyDefaultExpression,
  RawRequestDefaultExpression,
  RawServerDefault,
} from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import type { ChannelAddress } from "../domain/channel.ts";
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
  getHome(): Promise<Home>;
  /** The alerts behind an Alertmanager's tile; null when the instance has none. */
  listAlertmanagerAlerts(instance: string): Promise<AlertmanagerAlertList | null>;
}

/** The app with Zod schemas typing each route's request and reply. */
export type Api = FastifyInstance<
  RawServerDefault,
  RawRequestDefaultExpression,
  RawReplyDefaultExpression,
  FastifyBaseLogger,
  ZodTypeProvider
>;
