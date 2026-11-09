// Alertmanager's alerts for the tests of src/domain/overview.ts.
import type { AlertmanagerAlert } from "../../src/domain/overview.ts";

export const readAt = new Date("2026-10-13T10:00:00Z");
export const minutesBefore = (minutes: number) => new Date(readAt.getTime() - minutes * 60_000);

/** An active alert named `name`, routed to `team`, started an hour before the read. */
export function alert(
  name: string,
  fields: Partial<Omit<AlertmanagerAlert, "labels">> & { severity?: string } = {},
): AlertmanagerAlert {
  const { severity, ...rest } = fields;
  return {
    fingerprint: `fp-${name}`,
    labels: severity === undefined ? { alertname: name } : { alertname: name, severity },
    annotations: {},
    startsAt: minutesBefore(60),
    state: "active",
    silencedBy: [],
    inhibitedBy: [],
    receivers: ["team"],
    ...rest,
  };
}

export const silenced = { state: "suppressed", silencedBy: ["s1"] } as const;
export const inhibited = { state: "suppressed", inhibitedBy: ["fp-cause"] } as const;

/** No alert name ignored: every alert counts. */
export const nothingIgnored: ReadonlySet<string> = new Set();
