import { type IrmEndpoint, IrmError, listHeartbeatMissingGroups } from "../clients/irm.ts";
import { type IrmHeartbeat, irmHeartbeatOf } from "../domain/irm-heartbeat.ts";
import { cachedRead, type Reading } from "./alertmanager-reads.ts";

// IRM resolves a missed heartbeat about 2 minutes after it resumes, so a minute-old read
// is recent enough, and the Home view costs one request per integration a minute (ADR 0012).
const irmReads = { freshForMs: 60_000, failure: IrmError };

export type IrmHeartbeatReading = Reading<IrmHeartbeat, IrmError>;

/** Whether Grafana IRM receives each instance's heartbeat, read at most once a minute. */
export interface IrmHeartbeats {
  /**
   * Each instance's reading, by instance name; an instance is left out when IRM isn't
   * configured or the instance has no integration.
   */
  readAll(): Promise<ReadonlyMap<string, IrmHeartbeatReading>>;
}

export interface IrmHeartbeatsOptions {
  readonly now?: () => Date;
  /** IRM could not be read; the home view shows the last heartbeat meanwhile. */
  readonly onReadError?: (integrationId: string, error: IrmError) => void;
}

/**
 * Reads `irm` for each instance's integration in `integrations` (instance name →
 * integration ID), once per integration; none when `irm` is null.
 */
export function irmHeartbeatsFrom(
  irm: IrmEndpoint | null,
  integrations: ReadonlyMap<string, string>,
  { now = () => new Date(), onReadError = () => {} }: IrmHeartbeatsOptions = {},
): IrmHeartbeats {
  const byIntegration = new Map(
    irm === null
      ? []
      : [...new Set(integrations.values())].map((integrationId) => [
          integrationId,
          cachedRead(
            async () =>
              irmHeartbeatOf(integrationId, await listHeartbeatMissingGroups(irm, integrationId)),
            now,
            (error) => onReadError(integrationId, error),
            irmReads,
          ),
        ]),
  );
  return {
    readAll: async () =>
      new Map(
        await Promise.all(
          [...integrations].flatMap(([instance, integrationId]) => {
            const cache = byIntegration.get(integrationId);
            return cache === undefined
              ? []
              : [cache.read().then((reading) => [instance, reading] as const)];
          }),
        ),
      ),
  };
}
