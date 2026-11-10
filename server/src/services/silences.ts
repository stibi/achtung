import {
  type AlertmanagerEndpoint,
  AlertmanagerError,
  createSilence,
  expireSilence,
  listSilences,
} from "../clients/alertmanager.ts";
import type { Database } from "../db/client.ts";
import { findOccurrence } from "../db/queries.ts";
import type { Occurrence } from "../domain/occurrence.ts";
import {
  isActive,
  isExactlyFor,
  matchersFor,
  type Silence,
  type SilencedOccurrence,
  silencedUntil,
} from "../domain/silence.ts";
import { alertmanagerSource } from "../sources/alertmanager/index.ts";
import { alertmanagerReads, cachedRead } from "./alertmanager-reads.ts";

/** Alertmanager decides what is silenced (ADR 0008); this asks it, per instance. */
export interface Silences {
  /** Whether Achtung knows the instance's Alertmanager. */
  canSilence(instance: string): boolean;
  /** Each occurrence with the end of the silence that mutes it now, if any. */
  annotate(occurrences: readonly Occurrence[]): Promise<SilencedOccurrence[]>;
  /**
   * Silences exactly this alert on its instance's Alertmanager until `durationSeconds`
   * from now; returns the end. An exact silence it already has is changed to end then,
   * longer or shorter, rather than another one added (ADR 0015).
   */
  create(occurrence: Occurrence, durationSeconds: number): Promise<Date>;
  /**
   * Ends the alert's exact silences now. Broader ones, which mute other alerts too, are
   * left alone (ADR 0015); `silencedUntil` is when the latest of those that mutes the
   * alert ends, from the same fresh read.
   */
  end(occurrence: Occurrence): Promise<{ ended: number; silencedUntil: Date | null }>;
  /** Every instance's silences that mute alerts now, the soonest to end first. */
  listActive(): Promise<InstanceSilence[]>;
  /** The silences that mute alerts on the instance now, reading only its Alertmanager. */
  activeOn(instance: string): Promise<Silence[]>;
}

export type InstanceSilence = Silence & { readonly instance: string };

export interface SilencesOptions {
  readonly now?: () => Date;
  /** An Alertmanager could not be read; the last silences it reported are used meanwhile. */
  readonly onReadError?: (instance: string, error: AlertmanagerError) => void;
}

export function silencesFrom(
  endpoints: ReadonlyMap<string, AlertmanagerEndpoint>,
  { now = () => new Date(), onReadError = () => {} }: SilencesOptions = {},
): Silences {
  const caches = new Map(
    [...endpoints].map(([instance, endpoint]) => [
      instance,
      cachedRead(
        () => listSilences(endpoint),
        now,
        (error) => onReadError(instance, error),
        alertmanagerReads,
      ),
    ]),
  );
  // The last silences read, or none: a down Alertmanager doesn't fail a read (ADR 0008).
  const silencesOf = async (instance: string): Promise<readonly Silence[]> =>
    (await caches.get(instance)?.read())?.last?.value ?? [];
  const activeOn = async (instance: string): Promise<Silence[]> => {
    const silences = await silencesOf(instance);
    const at = now();
    return silences.filter((silence) => isActive(silence, at));
  };

  const endpointOf = (occurrence: Occurrence): AlertmanagerEndpoint => {
    const endpoint = endpoints.get(occurrence.instance);
    if (endpoint === undefined) {
      throw new Error(`no Alertmanager for instance ${occurrence.instance}`);
    }
    return endpoint;
  };
  return {
    canSilence: (instance) => endpoints.has(instance),

    async annotate(occurrences) {
      const instances = [...new Set(occurrences.map((occurrence) => occurrence.instance))];
      const byInstance = new Map(
        await Promise.all(
          instances.map(async (instance) => [instance, await silencesOf(instance)] as const),
        ),
      );
      const at = now();
      return occurrences.map((occurrence) => ({
        ...occurrence,
        silencedUntil: silencedUntil(
          occurrence.labels,
          byInstance.get(occurrence.instance) ?? [],
          at,
        ),
      }));
    },

    async create(occurrence, durationSeconds) {
      try {
        return await setExactSilence(endpointOf(occurrence), occurrence, durationSeconds, now());
      } finally {
        caches.get(occurrence.instance)?.invalidate();
      }
    },

    async end(occurrence) {
      try {
        return await endExactSilences(endpointOf(occurrence), occurrence, now());
      } finally {
        caches.get(occurrence.instance)?.invalidate();
      }
    },

    async listActive() {
      const perInstance = await Promise.all(
        [...caches.keys()].map(async (instance) =>
          (await activeOn(instance)).map((silence) => ({ ...silence, instance })),
        ),
      );
      return perInstance.flat().toSorted((a, b) => a.endsAt.getTime() - b.endsAt.getTime());
    },

    activeOn,
  };
}

// Read fresh, not from the cache: a change must see every silence there is now.
async function exactAndOtherSilences(
  endpoint: AlertmanagerEndpoint,
  occurrence: Occurrence,
  now: Date,
): Promise<{ exact: Silence[]; others: Silence[] }> {
  const current = (await listSilences(endpoint)).filter((silence) => silence.endsAt > now);
  const exact = current.filter((silence) => isExactlyFor(silence, occurrence.labels));
  return { exact, others: current.filter((silence) => !exact.includes(silence)) };
}

async function setExactSilence(
  endpoint: AlertmanagerEndpoint,
  occurrence: Occurrence,
  durationSeconds: number,
  startsAt: Date,
): Promise<Date> {
  const endsAt = new Date(startsAt.getTime() + durationSeconds * 1000);
  // The latest-ending exact silence is changed; any others would outlast a shorter end.
  const { exact } = await exactAndOtherSilences(endpoint, occurrence, startsAt);
  const [kept, ...extra] = exact.toSorted((a, b) => b.endsAt.getTime() - a.endsAt.getTime());
  // Alertmanager changes a silence in place only with the same matchers and, once it has
  // started, the same start; otherwise it ends it and makes a new one (ADR 0015).
  const started = kept !== undefined && kept.startsAt <= startsAt;
  await createSilence(endpoint, {
    ...(kept === undefined ? {} : { id: kept.id }),
    matchers: started ? kept.matchers : matchersFor(occurrence.labels),
    startsAt: started ? kept.startsAt : startsAt,
    endsAt,
    // There are no users to name (ADR 0002).
    createdBy: "Achtung",
    comment: `Silenced from Achtung: ${occurrence.instance} #${occurrence.channel}, ${occurrence.title}`,
  });
  for (const silence of extra) {
    await expireSilence(endpoint, silence.id);
  }
  return endsAt;
}

async function endExactSilences(
  endpoint: AlertmanagerEndpoint,
  occurrence: Occurrence,
  now: Date,
): Promise<{ ended: number; silencedUntil: Date | null }> {
  const { exact, others } = await exactAndOtherSilences(endpoint, occurrence, now);
  for (const silence of exact) {
    await expireSilence(endpoint, silence.id);
  }
  return { ended: exact.length, silencedUntil: silencedUntil(occurrence.labels, others, now) };
}

export type SilenceResult =
  | { readonly kind: "silenced"; readonly occurrence: SilencedOccurrence }
  | { readonly kind: "not-found" }
  /** Achtung has no Alertmanager to silence it on, or (ending) no silence of its own to end. */
  | { readonly kind: "not-silenceable"; readonly reason: string }
  /** Alertmanager was unreachable or refused the silence. */
  | { readonly kind: "failed"; readonly reason: string };

/** Silences an occurrence's alert for `durationSeconds`, on its instance's Alertmanager. */
export function silenceOccurrence(
  db: Database,
  silences: Silences,
  id: number,
  durationSeconds: number,
): Promise<SilenceResult> {
  return changeSilence(db, silences, id, async (occurrence) => {
    const endsAt = await silences.create(occurrence, durationSeconds);
    const [annotated] = await silences.annotate([occurrence]);
    // A re-read that failed must not hide the silence that was just created.
    const known = annotated?.silencedUntil ?? null;
    return {
      kind: "silenced",
      occurrence: {
        ...occurrence,
        silencedUntil: known !== null && known > endsAt ? known : endsAt,
      },
    };
  });
}

/**
 * Ends the occurrence's alert's own silences (exactly its labels) now. The answer still
 * says `silencedUntil` when a broader silence mutes it; when only such a one does,
 * nothing is ended and it is `not-silenceable` (ADR 0015).
 */
export function unsilenceOccurrence(
  db: Database,
  silences: Silences,
  id: number,
): Promise<SilenceResult> {
  return changeSilence(db, silences, id, async (occurrence) => {
    // From the read that decided what to end, not a re-read that could fail and hide one.
    const { ended, silencedUntil } = await silences.end(occurrence);
    if (ended === 0 && silencedUntil !== null) {
      return {
        kind: "not-silenceable",
        reason: "A silence that also mutes other alerts covers this one; end it in Alertmanager",
      };
    }
    return { kind: "silenced", occurrence: { ...occurrence, silencedUntil } };
  });
}

async function changeSilence(
  db: Database,
  silences: Silences,
  id: number,
  change: (occurrence: Occurrence) => Promise<SilenceResult>,
): Promise<SilenceResult> {
  const occurrence = await findOccurrence(db, id);
  if (occurrence === null) {
    return { kind: "not-found" };
  }
  if (occurrence.source !== alertmanagerSource.id) {
    return { kind: "not-silenceable", reason: `${occurrence.source} alerts can't be silenced` };
  }
  if (!silences.canSilence(occurrence.instance)) {
    return {
      kind: "not-silenceable",
      reason: `No Alertmanager is configured for instance ${occurrence.instance}`,
    };
  }
  try {
    return await change(occurrence);
  } catch (error) {
    if (error instanceof AlertmanagerError) {
      return { kind: "failed", reason: error.message };
    }
    throw error;
  }
}
