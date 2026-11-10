/**
 * How long an occurrence must stay gone from its Alertmanager, read after read, before
 * Achtung resolves it (ADR 0014). A restarted Alertmanager without its state learns its
 * alerts again from Prometheus within a minute or two; this outlasts that.
 */
export const vanishAfterMs = 5 * 60 * 1000;

/** Per occurrence id: the first read in an unbroken run of reads that didn't have it. */
export type Absences = ReadonlyMap<number, Date>;

/**
 * Folds one successful read of an instance's Alertmanager into its absences: `gone` are
 * the occurrences it didn't have. One the read had again drops out, so a later absence
 * starts over. `due` are those gone for at least `vanishAfterMs`, with when that began.
 */
export function trackAbsences<T extends { readonly id: number }>(
  previous: Absences,
  gone: readonly T[],
  readAt: Date,
): { readonly absences: Absences; readonly due: readonly { occurrence: T; since: Date }[] } {
  const tracked = gone.map((occurrence) => ({
    occurrence,
    since: previous.get(occurrence.id) ?? readAt,
  }));
  return {
    absences: new Map(tracked.map(({ occurrence, since }) => [occurrence.id, since])),
    due: tracked.filter(({ since }) => readAt.getTime() - since.getTime() >= vanishAfterMs),
  };
}
