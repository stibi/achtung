import type { Severity } from "./alert.ts";
import type { InstanceName } from "./channel.ts";

/** One label an occurrence must have, with exactly this value. */
export interface LabelFilter {
  readonly name: string;
  readonly value: string;
}

/**
 * What a list of occurrences is narrowed to (ADR 0017). Every part that is given must
 * match; an empty one matches everything.
 */
export interface OccurrenceSearch {
  /** Found, ignoring case and taken literally, in the title, summary or a label. */
  readonly text: string | null;
  /** Every one must match exactly. */
  readonly labels: readonly LabelFilter[];
  /** Any one of them. */
  readonly severities: readonly Severity[];
  readonly instance: InstanceName | null;
}

/**
 * `name=value`, split at the first `=`, so a value may contain one. Null without a name
 * or an `=`.
 */
export function parseLabelFilter(text: string): LabelFilter | null {
  const at = text.indexOf("=");
  if (at <= 0) {
    return null;
  }
  return { name: text.slice(0, at), value: text.slice(at + 1) };
}
