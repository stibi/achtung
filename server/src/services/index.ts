import type { Database } from "../db/client.ts";
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
import { type Silences, silenceOccurrence } from "./silences.ts";

/**
 * Every use case bound to one database, the instances' Alertmanagers and Grafana IRM:
 * what src/http needs to serve requests.
 */
export function servicesFor(
  db: Database,
  monitors: {
    readonly silences: Silences;
    readonly alerts: AlertmanagerAlerts;
    readonly heartbeats: IrmHeartbeats;
  },
  now: () => Date = () => new Date(),
) {
  const { silences, alerts, heartbeats } = monitors;
  return {
    ingest: (notification: Parameters<typeof ingestNotification>[1]) =>
      ingestNotification(db, notification),
    listChannels: () => listChannels(db),
    listChannelOccurrences: (
      ...args: DropFirst<DropFirst<Parameters<typeof listChannelOccurrences>>>
    ) => listChannelOccurrences(db, silences, ...args),
    listOccurrences: (filter: Parameters<typeof listAllOccurrences>[2]) =>
      listAllOccurrences(db, silences, filter),
    getOccurrence: (id: number) => getOccurrence(db, silences, id),
    silenceOccurrence: (id: number, durationSeconds: number) =>
      silenceOccurrence(db, silences, id, durationSeconds),
    getHome: () => getHome(db, silences, alerts, heartbeats, now()),
    listAlertmanagerAlerts: (instance: string) =>
      listAlertmanagerAlerts(db, silences, alerts, instance),
    getIgnoredAlertNames: () => getIgnoredAlertNames(db),
    setIgnoredAlertNames: (names: readonly string[]) => setIgnoredAlertNames(db, names, now()),
  };
}

type DropFirst<T extends readonly unknown[]> = T extends readonly [unknown, ...infer Rest]
  ? Rest
  : never;
