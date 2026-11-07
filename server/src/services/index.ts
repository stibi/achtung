import type { Database } from "../db/client.ts";
import { getOccurrence, listChannelOccurrences, listChannels } from "./inbox.ts";
import { ingestNotification } from "./ingest.ts";

/** Every use case bound to one database: what src/http needs to serve requests. */
export function servicesFor(db: Database) {
  return {
    ingest: (notification: Parameters<typeof ingestNotification>[1]) =>
      ingestNotification(db, notification),
    listChannels: () => listChannels(db),
    listChannelOccurrences: (...args: DropFirst<Parameters<typeof listChannelOccurrences>>) =>
      listChannelOccurrences(db, ...args),
    getOccurrence: (id: number) => getOccurrence(db, id),
  };
}

type DropFirst<T extends readonly unknown[]> = T extends readonly [unknown, ...infer Rest]
  ? Rest
  : never;
