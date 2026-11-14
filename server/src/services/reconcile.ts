import type { Database } from "../db/client.ts";
import { resolveVanished } from "../db/occurrences.ts";
import { listFiringOccurrences } from "../db/queries.ts";
import type { Occurrence } from "../domain/occurrence.ts";
import { type AlertmanagerAlert, goneFromAlertmanager } from "../domain/overview.ts";
import { type Absences, trackAbsences } from "../domain/vanished.ts";
import { alertmanagerSource } from "../sources/alertmanager/index.ts";
import type { Changes } from "./changes.ts";
import type { AlertmanagerAlerts } from "./home.ts";

interface ReconcileSummary {
  /** The occurrences resolved by this run, by id. */
  readonly resolved: readonly number[];
}

/**
 * Resolves the occurrences that fire in Achtung but are gone from their Alertmanager, a
 * resolve that never arrived, e.g. of a silenced alert (ADR 0014). Call `run` regularly:
 * it reads each Alertmanager through the shared cache, and resolves an occurrence once
 * every successful read for `vanishAfterMs` lacked it. It remembers absences in memory,
 * per instance; a failed read, or one listing no alerts at all, forgets that instance's,
 * so the count starts over. A run that resolved any publishes it to `changes` (ADR 0019).
 */
export interface Reconciler {
  run(): Promise<ReconcileSummary>;
}

export function reconcilerFor(
  db: Database,
  alerts: AlertmanagerAlerts,
  changes: Changes,
  now: () => Date = () => new Date(),
): Reconciler {
  const absencesByInstance = new Map<string, Absences>();

  async function reconcileInstance(
    instance: string,
    read: { readonly value: readonly AlertmanagerAlert[]; readonly readAt: Date },
    firing: readonly Occurrence[],
  ): Promise<number[]> {
    const ours = firing.filter(
      (occurrence) =>
        occurrence.instance === instance && occurrence.source === alertmanagerSource.id,
    );
    const { absences, due } = trackAbsences(
      absencesByInstance.get(instance) ?? new Map(),
      goneFromAlertmanager(read.value, ours, read.readAt),
      read.readAt,
    );
    absencesByInstance.set(instance, absences);
    const resolved: number[] = [];
    for (const { occurrence, since } of due) {
      const done = await db.transaction((tx) =>
        resolveVanished(
          tx,
          occurrence.id,
          { lastReceivedAt: occurrence.lastReceivedAt, endsAt: since },
          now(),
        ),
      );
      if (done) {
        resolved.push(occurrence.id);
      }
    }
    return resolved;
  }

  return {
    run: async () => {
      const [readings, firing] = await Promise.all([alerts.readAll(), listFiringOccurrences(db)]);
      const resolved: number[] = [];
      for (const { instance, reading } of readings) {
        // An empty list is no proof either: every Alertmanager has its Watchdog firing,
        // so it is one that just started, or isn't the one Achtung's alerts came from.
        if (reading.error !== null || reading.last === null || reading.last.value.length === 0) {
          absencesByInstance.delete(instance);
          continue;
        }
        resolved.push(...(await reconcileInstance(instance, reading.last, firing)));
      }
      if (resolved.length > 0) {
        changes.publish("occurrences");
      }
      return { resolved };
    },
  };
}
