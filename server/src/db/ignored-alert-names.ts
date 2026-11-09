import { notInArray, sql } from "drizzle-orm";
import type { Database, Transaction } from "./client.ts";
import { ignoredAlertNames } from "./schema.ts";

/** The alert names the Home views leave out (ADR 0011), in no particular order. */
export async function listIgnoredAlertNames(db: Database | Transaction): Promise<string[]> {
  const rows = await db.select({ name: ignoredAlertNames.name }).from(ignoredAlertNames);
  return rows.map((row) => row.name);
}

/**
 * Makes the list exactly `names`. A name already there keeps its `created_at`. Call it in
 * a transaction: it locks the table first, so concurrent replacements run one after the
 * other and the last one wins whole, instead of the two merging.
 */
export async function replaceIgnoredAlertNames(
  tx: Transaction,
  names: readonly string[],
  at: Date,
): Promise<void> {
  // Conflicts with itself, not with reads.
  await tx.execute(sql`lock table ${ignoredAlertNames} in share row exclusive mode`);
  await tx
    .delete(ignoredAlertNames)
    .where(names.length === 0 ? undefined : notInArray(ignoredAlertNames.name, [...names]));
  if (names.length > 0) {
    await tx
      .insert(ignoredAlertNames)
      .values(names.map((name) => ({ name, createdAt: at })))
      .onConflictDoNothing();
  }
}
