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
   * The same for several alerts of one instance at once, each with its own exact silence,
   * reading the instance's silences once; returns the end (ADR 0016).
   */
  createEach(
    instance: string,
    targets: readonly SilenceTarget[],
    durationSeconds: number,
  ): Promise<Date>;
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

/** An alert to silence exactly: its labels, and what the silence's comment says. */
interface SilenceTarget {
  readonly labels: Readonly<Record<string, string>>;
  readonly comment: string;
}

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

  const endpointOf = (instance: string): AlertmanagerEndpoint => {
    const endpoint = endpoints.get(instance);
    if (endpoint === undefined) {
      throw new Error(`no Alertmanager for instance ${instance}`);
    }
    return endpoint;
  };
  // A change reads and writes the instance's Alertmanager directly, then forgets the cache.
  const changing = async <T>(
    instance: string,
    change: (endpoint: AlertmanagerEndpoint) => Promise<T>,
  ): Promise<T> => {
    try {
      return await change(endpointOf(instance));
    } finally {
      caches.get(instance)?.invalidate();
    }
  };
  const createEach = (
    instance: string,
    targets: readonly SilenceTarget[],
    durationSeconds: number,
  ): Promise<Date> =>
    changing(instance, (endpoint) => setExactSilences(endpoint, targets, durationSeconds, now()));

  return {
    canSilence: (instance) => endpoints.has(instance),

    annotate: (occurrences) => annotate(occurrences, silencesOf, now),

    create: (occurrence, durationSeconds) =>
      createEach(occurrence.instance, [targetOf(occurrence)], durationSeconds),

    createEach,

    end: (occurrence) =>
      changing(occurrence.instance, (endpoint) => endExactSilences(endpoint, occurrence, now())),

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

async function annotate(
  occurrences: readonly Occurrence[],
  silencesOf: (instance: string) => Promise<readonly Silence[]>,
  now: () => Date,
): Promise<SilencedOccurrence[]> {
  const instances = [...new Set(occurrences.map((occurrence) => occurrence.instance))];
  const byInstance = new Map(
    await Promise.all(
      instances.map(async (instance) => [instance, await silencesOf(instance)] as const),
    ),
  );
  const at = now();
  return occurrences.map((occurrence) => ({
    ...occurrence,
    silencedUntil: silencedUntil(occurrence.labels, byInstance.get(occurrence.instance) ?? [], at),
  }));
}

const targetOf = (occurrence: Occurrence): SilenceTarget => ({
  labels: occurrence.labels,
  comment: `Silenced from Achtung: ${occurrence.instance} #${occurrence.channel}, ${occurrence.title}`,
});

async function setExactSilences(
  endpoint: AlertmanagerEndpoint,
  targets: readonly SilenceTarget[],
  durationSeconds: number,
  startsAt: Date,
): Promise<Date> {
  const endsAt = new Date(startsAt.getTime() + durationSeconds * 1000);
  // Read fresh, not from the cache: a change must see every silence there is now.
  const current = await currentSilences(endpoint, startsAt);
  for (const target of targets) {
    await setExactSilence(endpoint, current, target, { startsAt, endsAt });
  }
  return endsAt;
}

async function currentSilences(endpoint: AlertmanagerEndpoint, now: Date): Promise<Silence[]> {
  return (await listSilences(endpoint)).filter((silence) => silence.endsAt > now);
}

async function setExactSilence(
  endpoint: AlertmanagerEndpoint,
  current: readonly Silence[],
  { labels, comment }: SilenceTarget,
  { startsAt, endsAt }: { readonly startsAt: Date; readonly endsAt: Date },
): Promise<void> {
  // The latest-ending exact silence is changed; any others would outlast a shorter end.
  const [kept, ...extra] = current
    .filter((silence) => isExactlyFor(silence, labels))
    .toSorted((a, b) => b.endsAt.getTime() - a.endsAt.getTime());
  // Alertmanager changes a silence in place only with the same matchers and, once it has
  // started, the same start; otherwise it ends it and makes a new one (ADR 0015).
  const started = kept !== undefined && kept.startsAt <= startsAt;
  await createSilence(endpoint, {
    ...(kept === undefined ? {} : { id: kept.id }),
    matchers: started ? kept.matchers : matchersFor(labels),
    startsAt: started ? kept.startsAt : startsAt,
    endsAt,
    // There are no users to name (ADR 0002).
    createdBy: "Achtung",
    comment,
  });
  for (const silence of extra) {
    await expireSilence(endpoint, silence.id);
  }
}

async function endExactSilences(
  endpoint: AlertmanagerEndpoint,
  occurrence: Occurrence,
  now: Date,
): Promise<{ ended: number; silencedUntil: Date | null }> {
  const current = await currentSilences(endpoint, now);
  const exact = current.filter((silence) => isExactlyFor(silence, occurrence.labels));
  for (const silence of exact) {
    await expireSilence(endpoint, silence.id);
  }
  const others = current.filter((silence) => !exact.includes(silence));
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
