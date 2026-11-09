import { asc, sql } from "drizzle-orm";
import { describe, expect, it } from "vitest";
import { ignoredAlertNames } from "../../src/db/schema.ts";
import { setIgnoredAlertNames } from "../../src/services/settings.ts";
import { createTestDatabase, openConnections } from "../database.ts";

const at = (time: string) => new Date(`2026-10-13T${time}Z`);

describe("setIgnoredAlertNames", () => {
  it("keeps when a name already on the list was added", async () => {
    const { db } = await createTestDatabase();
    await setIgnoredAlertNames(db, ["Watchdog", "Heartbeat"], at("10:00:00"));

    await setIgnoredAlertNames(db, ["Heartbeat", "Other"], at("11:00:00"));

    const rows = await db
      .select()
      .from(ignoredAlertNames)
      .orderBy(asc(sql`${ignoredAlertNames.name} collate "C"`));
    expect(rows).toEqual([
      { name: "Heartbeat", createdAt: at("10:00:00") },
      { name: "Other", createdAt: at("11:00:00") },
    ]);
  });

  it("replaces a list another transaction writes meanwhile, instead of merging with it", async () => {
    const connection = await createTestDatabase();
    const { db, pool } = connection;
    await openConnections(connection, 2);

    // Another writer, mid-way through its own replacement when this one starts.
    const other = await pool.connect();
    await other.query("begin");
    await other.query("delete from ignored_alert_names");
    await other.query("insert into ignored_alert_names values ('Theirs', now())");
    const replacing = setIgnoredAlertNames(db, ["Mine"], at("10:00:00"));
    await new Promise((settle) => setTimeout(settle, 200));
    await other.query("commit");
    other.release();

    expect(await replacing).toEqual(["Mine"]);
  });
});
