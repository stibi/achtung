import { z } from "zod";
import type { IrmHeartbeatReading } from "../services/irm-heartbeats.ts";
import { timestamp } from "./api-schemas.ts";

// The IRM heartbeat on a Home tile (ADR 0012), next to home.ts, which uses it.

export const irmHeartbeatBody = z
  .object({
    status: z
      .enum(["receiving", "missing", "unknown"])
      .describe(
        "receiving: IRM has no open missed-heartbeat alert group for the integration; missing: it has one; unknown: IRM was never read successfully",
      ),
    since: timestamp
      .nullable()
      .describe("While missing, when IRM opened the group for it; else null"),
    lastMissedFrom: timestamp
      .nullable()
      .describe("While receiving, when the last missed heartbeat started; else null"),
    lastMissedTo: timestamp
      .nullable()
      .describe("While receiving, when IRM resolved the last missed heartbeat; else null"),
    checkedAt: timestamp
      .nullable()
      .describe("When IRM was last read successfully; the fields above are from that read"),
    error: z.string().nullable().describe("Why the latest read of IRM failed; null when it worked"),
  })
  .describe(
    "Whether Grafana IRM receives the heartbeat this Alertmanager sends it, read at most once a minute",
  )
  .meta({ id: "IrmHeartbeat" });

export function toIrmHeartbeatBody({
  last,
  error,
}: IrmHeartbeatReading): z.infer<typeof irmHeartbeatBody> {
  const known = {
    checkedAt: last?.readAt.toISOString() ?? null,
    error: error?.message ?? null,
  };
  const heartbeat = last?.value;
  if (heartbeat === undefined) {
    return { status: "unknown", since: null, lastMissedFrom: null, lastMissedTo: null, ...known };
  }
  if (heartbeat.status === "missing") {
    const since = heartbeat.since.toISOString();
    return { status: "missing", since, lastMissedFrom: null, lastMissedTo: null, ...known };
  }
  return {
    status: "receiving",
    since: null,
    lastMissedFrom: heartbeat.lastMissed?.from.toISOString() ?? null,
    lastMissedTo: heartbeat.lastMissed?.to.toISOString() ?? null,
    ...known,
  };
}
