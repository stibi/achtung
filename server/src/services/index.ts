import type { Database } from "../db/client.ts";
import { type AlertmanagerAlerts, getHome } from "./home.ts";
import {
  getOccurrence,
  listAllOccurrences,
  listChannelOccurrences,
  listChannels,
} from "./inbox.ts";
import { ingestNotification } from "./ingest.ts";
import { type Silences, silenceOccurrence } from "./silences.ts";

/**
 * Every use case bound to one database and the instances' Alertmanagers: what src/http
 * needs to serve requests.
 */
export function servicesFor(
  db: Database,
  alertmanagers: { readonly silences: Silences; readonly alerts: AlertmanagerAlerts },
  now: () => Date = () => new Date(),
) {
  const { silences, alerts } = alertmanagers;
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
    getHome: () => getHome(db, silences, alerts, now()),
  };
}

type DropFirst<T extends readonly unknown[]> = T extends readonly [unknown, ...infer Rest]
  ? Rest
  : never;
