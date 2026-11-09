import {
  type AlertmanagerEndpoint,
  AlertmanagerError,
  createSilence,
  listSilences,
} from "../clients/alertmanager.ts";
import type { Database } from "../db/client.ts";
import { findOccurrence } from "../db/queries.ts";
import type { Occurrence } from "../domain/occurrence.ts";
import {
  isActive,
  matchersFor,
  type Silence,
  type SilencedOccurrence,
  silencedUntil,
} from "../domain/silence.ts";
import { alertmanagerSource } from "../sources/alertmanager/index.ts";
import { cachedRead } from "./alertmanager-reads.ts";

/** Alertmanager decides what is silenced (ADR 0008); this asks it, per instance. */
export interface Silences {
  /** Whether Achtung knows the instance's Alertmanager. */
  canSilence(instance: string): boolean;
  /** Each occurrence with the end of the silence that mutes it now, if any. */
  annotate(occurrences: readonly Occurrence[]): Promise<SilencedOccurrence[]>;
  /** Silences exactly this alert on its instance's Alertmanager, from now; returns the end. */
  create(occurrence: Occurrence, durationSeconds: number): Promise<Date>;
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
      const endpoint = endpoints.get(occurrence.instance);
      if (endpoint === undefined) {
        throw new Error(`no Alertmanager for instance ${occurrence.instance}`);
      }
      const startsAt = now();
      const endsAt = new Date(startsAt.getTime() + durationSeconds * 1000);
      await createSilence(endpoint, {
        matchers: matchersFor(occurrence.labels),
        startsAt,
        endsAt,
        // There are no users to name (ADR 0002).
        createdBy: "Achtung",
        comment: `Silenced from Achtung: ${occurrence.instance} #${occurrence.channel}, ${occurrence.title}`,
      });
      caches.get(occurrence.instance)?.invalidate();
      return endsAt;
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

export type SilenceResult =
  | { readonly kind: "silenced"; readonly occurrence: SilencedOccurrence }
  | { readonly kind: "not-found" }
  /** Achtung has no Alertmanager to silence it on. */
  | { readonly kind: "not-silenceable"; readonly reason: string }
  /** Alertmanager was unreachable or refused the silence. */
  | { readonly kind: "failed"; readonly reason: string };

/** Silences an occurrence's alert for `durationSeconds`, on its instance's Alertmanager. */
export async function silenceOccurrence(
  db: Database,
  silences: Silences,
  id: number,
  durationSeconds: number,
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
  let endsAt: Date;
  try {
    endsAt = await silences.create(occurrence, durationSeconds);
  } catch (error) {
    if (error instanceof AlertmanagerError) {
      return { kind: "failed", reason: error.message };
    }
    throw error;
  }
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
}
