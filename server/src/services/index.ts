import type { Database } from "../db/client.ts";
import { silenceAlertmanagerAlerts } from "./alertmanager-silences.ts";
import type { ChangeKind, Changes } from "./changes.ts";
import { type AlertmanagerAlerts, getHome, listAlertmanagerAlerts } from "./home.ts";
import {
  getOccurrence,
  listAllOccurrences,
  listChannelOccurrences,
  listChannels,
} from "./inbox.ts";
import { ingestNotification } from "./ingest.ts";
import type { IrmHeartbeats } from "./irm-heartbeats.ts";
import { getIgnoredAlertNames, setIgnoredAlertNames } from "./settings.ts";
import { type Silences, silenceOccurrence, unsilenceOccurrence } from "./silences.ts";

/**
 * Every use case bound to one database, the instances' Alertmanagers and Grafana IRM:
 * what src/http needs to serve requests. Each change is published to `changes` (ADR 0019).
 */
export function servicesFor(
  db: Database,
  monitors: {
    readonly silences: Silences;
    readonly alerts: AlertmanagerAlerts;
    readonly heartbeats: IrmHeartbeats;
    readonly changes: Changes;
  },
  now: () => Date = () => new Date(),
) {
  const { silences, alerts, heartbeats, changes } = monitors;
  // Published whatever the result: a failed silence is a result too, and Alertmanager may
  // have taken part of it. A thrown error changed nothing to tell about.
  const changing = async <T>(kind: ChangeKind, change: Promise<T>) => {
    const result = await change;
    changes.publish(kind);
    return result;
  };
  return {
    changes,
    ingest: (notification: Parameters<typeof ingestNotification>[1]) =>
      changing("occurrences", ingestNotification(db, notification)),
    listChannels: () => listChannels(db),
    listChannelOccurrences: (
      ...args: DropFirst<DropFirst<Parameters<typeof listChannelOccurrences>>>
    ) => listChannelOccurrences(db, silences, ...args),
    listOccurrences: (filter: Parameters<typeof listAllOccurrences>[2]) =>
      listAllOccurrences(db, silences, filter),
    getOccurrence: (id: number) => getOccurrence(db, silences, id),
    silenceOccurrence: (id: number, durationSeconds: number) =>
      changing("silences", silenceOccurrence(db, silences, id, durationSeconds)),
    unsilenceOccurrence: (id: number) =>
      changing("silences", unsilenceOccurrence(db, silences, id)),
    silenceAlertmanagerAlerts: (
      instance: string,
      fingerprints: readonly string[],
      durationSeconds: number,
    ) =>
      changing(
        "silences",
        silenceAlertmanagerAlerts(silences, alerts, instance, fingerprints, durationSeconds),
      ),
    getHome: () => getHome(db, silences, alerts, heartbeats, now()),
    listAlertmanagerAlerts: (instance: string) =>
      listAlertmanagerAlerts(db, silences, alerts, instance),
    getIgnoredAlertNames: () => getIgnoredAlertNames(db),
    setIgnoredAlertNames: (names: readonly string[]) =>
      changing("settings", setIgnoredAlertNames(db, names, now())),
  };
}

type DropFirst<T extends readonly unknown[]> = T extends readonly [unknown, ...infer Rest]
  ? Rest
  : never;
