import { AlertmanagerError } from "../clients/alertmanager.ts";

// How long one read of an instance's Alertmanager is reused before it is asked again, so
// a page of occurrences or the home view costs at most one request per instance and kind.
const freshForMs = 30_000;

/** What is known from reading an Alertmanager. */
export interface Reading<T> {
  /** The last read that succeeded; null until one has. */
  readonly last: { readonly value: T; readonly readAt: Date } | null;
  /** Why the latest read failed; null when it succeeded. */
  readonly error: AlertmanagerError | null;
}

/** One kind of read from one instance's Alertmanager, made at most once per window. */
export interface CachedRead<T> {
  read(): Promise<Reading<T>>;
  /** Achtung just changed what is read: forget the read's age, and any read in flight. */
  invalidate(): void;
}

export function cachedRead<T>(
  fetch: () => Promise<T>,
  now: () => Date,
  onReadError: (error: AlertmanagerError) => void,
): CachedRead<T> {
  let known: { reading: Reading<T>; fetchedAt: number } | null = null;
  let pending: Promise<Reading<T>> | null = null;
  // Bumped by every invalidation: a read that started before it is outdated.
  let generation = 0;

  function fetchNow(): Promise<Reading<T>> {
    const startedIn = generation;
    const last = known?.reading.last ?? null;
    const request: Promise<Reading<T>> = fetch()
      .then((value): Reading<T> => ({ last: { value, readAt: now() }, error: null }))
      .catch((error: unknown): Reading<T> => {
        if (!(error instanceof AlertmanagerError)) {
          throw error;
        }
        onReadError(error);
        // Kept as if freshly read, so a down Alertmanager is asked once per window.
        return { last, error };
      })
      .then((reading) => {
        if (startedIn === generation) {
          known = { reading, fetchedAt: now().getTime() };
        }
        return reading;
      })
      .finally(() => {
        if (pending === request) {
          pending = null;
        }
      });
    pending = request;
    return request;
  }

  return {
    read() {
      if (known !== null && now().getTime() - known.fetchedAt < freshForMs) {
        return Promise.resolve(known.reading);
      }
      return pending ?? fetchNow();
    },
    invalidate() {
      generation += 1;
      // Stale, not forgotten: a read that fails next still falls back to what was read.
      known = known === null ? null : { ...known, fetchedAt: Number.NEGATIVE_INFINITY };
      pending = null;
    },
  };
}
