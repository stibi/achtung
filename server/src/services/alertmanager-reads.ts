import { AlertmanagerError } from "../clients/alertmanager.ts";

/** How one kind of read from another system is cached. */
interface ReadPolicy<E extends Error> {
  /** How long a read is reused before the system is asked again. */
  readonly freshForMs: number;
  /** The error class of an expected failure; any other error is a bug and is thrown. */
  readonly failure: abstract new (
    ...args: never[]
  ) => E;
}

// Each instance's Alertmanager is read at most every 30 seconds, so a page of occurrences
// or the home view costs at most one request per instance and kind (ADR 0008).
export const alertmanagerReads: ReadPolicy<AlertmanagerError> = {
  freshForMs: 30_000,
  failure: AlertmanagerError,
};

/** What is known from reading an Alertmanager, or another system. */
export interface Reading<T, E extends Error = AlertmanagerError> {
  /** The last read that succeeded; null until one has. */
  readonly last: { readonly value: T; readonly readAt: Date } | null;
  /** Why the latest read failed; null when it succeeded. */
  readonly error: E | null;
}

/** One kind of read from another system, e.g. an instance's Alertmanager, made at most once per window. */
export interface CachedRead<T, E extends Error = AlertmanagerError> {
  read(): Promise<Reading<T, E>>;
  /** Achtung just changed what is read: forget the read's age, and any read in flight. */
  invalidate(): void;
}

export function cachedRead<T, E extends Error>(
  fetch: () => Promise<T>,
  now: () => Date,
  onReadError: (error: E) => void,
  { freshForMs, failure }: ReadPolicy<E>,
): CachedRead<T, E> {
  let known: { reading: Reading<T, E>; fetchedAt: number } | null = null;
  let pending: Promise<Reading<T, E>> | null = null;
  // Bumped by every invalidation: a read that started before it is outdated.
  let generation = 0;

  function fetchNow(): Promise<Reading<T, E>> {
    const startedIn = generation;
    const last = known?.reading.last ?? null;
    const request: Promise<Reading<T, E>> = fetch()
      .then((value): Reading<T, E> => ({ last: { value, readAt: now() }, error: null }))
      .catch((error: unknown): Reading<T, E> => {
        if (!(error instanceof failure)) {
          throw error;
        }
        onReadError(error);
        // Kept as if freshly read, so a system that is down is asked once per window.
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
