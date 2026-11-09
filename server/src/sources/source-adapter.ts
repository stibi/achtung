import type { IncomingAlert } from "../domain/alert.ts";

type ParseResult =
  | {
      readonly ok: true;
      readonly alerts: readonly IncomingAlert[];
      /** Alerts the source dropped from this notification (e.g. Alertmanager max_alerts). */
      readonly truncatedAlerts: number;
      /**
       * The sender's name for the configuration that sent this notification, e.g.
       * Alertmanager's receiver; null when the source has none. Achtung records it on the
       * channel, to tell which of the sender's alerts should reach it (ADR 0010).
       */
      readonly receiver: string | null;
    }
  | { readonly ok: false; readonly error: string };

/**
 * Contract every alert source implements. An adapter turns the raw webhook body into
 * domain alerts and must not depend on HTTP, storage or other adapters.
 */
export interface SourceAdapter {
  /** URL-safe identifier, used in the ingest path: /ingest/{id}/{channel}. */
  readonly id: string;
  parse(body: unknown): ParseResult;
}
