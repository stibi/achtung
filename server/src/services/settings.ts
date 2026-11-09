import type { Database } from "../db/client.ts";
import { listIgnoredAlertNames, replaceIgnoredAlertNames } from "../db/ignored-alert-names.ts";

// Settings shared by every client (ADR 0011): there are no users (ADR 0002).

/** The alert names the Home views leave out, sorted. */
export async function getIgnoredAlertNames(db: Database): Promise<string[]> {
  return sorted(await listIgnoredAlertNames(db));
}

/**
 * Replaces the ignored alert names in one transaction and returns them as stored, sorted.
 * The names are valid already (src/http checks them); repeats are stored once.
 */
export function setIgnoredAlertNames(
  db: Database,
  names: readonly string[],
  at: Date,
): Promise<string[]> {
  return db.transaction(async (tx) => {
    await replaceIgnoredAlertNames(tx, [...new Set(names)], at);
    return sorted(await listIgnoredAlertNames(tx));
  });
}

function sorted(names: readonly string[]): string[] {
  return names.toSorted((a, b) => a.localeCompare(b));
}
