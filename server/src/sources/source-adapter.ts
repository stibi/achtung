import type { IncomingAlert } from "../domain/alert.ts";

type ParseResult =
  | {
      readonly ok: true;
      readonly alerts: readonly IncomingAlert[];
      /** Alerts the source dropped from this notification (e.g. Alertmanager max_alerts). */
      readonly truncatedAlerts: number;
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
