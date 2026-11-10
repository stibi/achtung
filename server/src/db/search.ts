import { and, eq, ilike, inArray, or, type SQL, sql } from "drizzle-orm";
import type { OccurrenceSearch } from "../domain/search.ts";
import { channels, occurrences } from "./schema.ts";

/**
 * The condition for a search over occurrences joined with their channel (ADR 0017).
 * There is no index behind the text: at a few thousand occurrences a scan is cheap.
 */
export function searchCondition({
  text,
  labels,
  severities,
  instance,
}: OccurrenceSearch): SQL | undefined {
  const pattern = text === null ? null : `%${literally(text)}%`;
  return and(
    pattern === null
      ? undefined
      : or(
          ilike(occurrences.title, pattern),
          ilike(occurrences.summary, pattern),
          // Names and values alike, as they are, not as JSON escapes them.
          sql`exists (select 1 from jsonb_each_text(${occurrences.labels}) as label
            where label.key ilike ${pattern} or label.value ilike ${pattern})`,
        ),
    // One containment per label: two values for one name match nothing, as they should.
    ...labels.map(
      ({ name, value }) =>
        sql`${occurrences.labels} @> ${JSON.stringify({ [name]: value })}::jsonb`,
    ),
    severities.length === 0 ? undefined : inArray(occurrences.severity, [...severities]),
    instance === null ? undefined : eq(channels.instance, instance),
  );
}

// ILIKE's wildcards and its escape character, made literal.
function literally(text: string): string {
  return text.replaceAll(/[\\%_]/g, (character) => `\\${character}`);
}
