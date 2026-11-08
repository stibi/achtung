import type { Occurrence } from "./occurrence.ts";

/** One condition of an Alertmanager silence, on one label. */
export interface LabelMatcher {
  readonly name: string;
  readonly value: string;
  readonly isRegex: boolean;
  /** False negates the match (`!=` or `!~`). */
  readonly isEqual: boolean;
}

/** A silence as Alertmanager reports it. It mutes every alert all its matchers match. */
export interface Silence {
  readonly id: string;
  readonly matchers: readonly LabelMatcher[];
  readonly startsAt: Date;
  readonly endsAt: Date;
}

/** An occurrence with the end of the silence that mutes it now, if any (ADR 0008). */
export type SilencedOccurrence = Occurrence & { readonly silencedUntil: Date | null };

/** Exactly this alert: one equality matcher per label, like Alertmanager's own button. */
export function matchersFor(labels: Readonly<Record<string, string>>): LabelMatcher[] {
  return Object.keys(labels)
    .sort()
    .map((name) => ({ name, value: labels[name] ?? "", isRegex: false, isEqual: true }));
}

/** When the latest silence muting `labels` at `now` ends; null when none does. */
export function silencedUntil(
  labels: Readonly<Record<string, string>>,
  silences: readonly Silence[],
  now: Date,
): Date | null {
  const ends = silences
    .filter((silence) => silence.startsAt <= now && silence.endsAt > now)
    .filter((silence) => silence.matchers.every((matcher) => matches(matcher, labels)))
    .map((silence) => silence.endsAt.getTime());
  return ends.length === 0 ? null : new Date(Math.max(...ends));
}

// Alertmanager treats a missing label as the empty string, and anchors regexes.
// A matcher Achtung can't evaluate never matches, negated or not, so an alert is never
// shown as silenced when Achtung can't tell.
function matches(matcher: LabelMatcher, labels: Readonly<Record<string, string>>): boolean {
  const value = labels[matcher.name] ?? "";
  const equal = matcher.isRegex ? regexMatches(matcher.value, value) : matcher.value === value;
  return equal !== null && equal === matcher.isEqual;
}

/** Null when JavaScript can't compile the RE2 pattern, e.g. one with a leading (?i). */
function regexMatches(pattern: string, value: string): boolean | null {
  try {
    return new RegExp(`^(?:${pattern})$`).test(value);
  } catch {
    return null;
  }
}
