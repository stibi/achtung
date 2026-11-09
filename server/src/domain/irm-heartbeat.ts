// Whether Grafana IRM receives an Alertmanager's heartbeat (ADR 0012). IRM opens an alert
// group with this title on the integration when the heartbeat stops, and resolves it when
// the heartbeat comes back.

/** The title of IRM's alert group for a missed heartbeat. IRM sends it with a trailing space. */
export const heartbeatMissingTitle = "OnCallHeartBeatMissing";

/** An IRM alert group, the fields the heartbeat needs. */
export interface IrmAlertGroup {
  readonly integrationId: string;
  readonly title: string;
  readonly state: "new" | "acknowledged" | "resolved" | "silenced";
  readonly createdAt: Date;
  /** Null unless resolved. */
  readonly resolvedAt: Date | null;
}

export type IrmHeartbeat =
  | {
      readonly status: "receiving";
      /** The latest missed heartbeat, IRM's group from its start to its resolve; null for none. */
      readonly lastMissed: { readonly from: Date; readonly to: Date } | null;
    }
  | {
      readonly status: "missing";
      /** When IRM opened the group for it. */
      readonly since: Date;
    };

/**
 * The heartbeat of the integration, from its latest alert groups, in any order. Only its
 * groups titled like a missed heartbeat count: IRM's name filter may match more, and the
 * integration is checked again so a filter IRM ignored can't show another cluster's.
 */
export function irmHeartbeatOf(
  integrationId: string,
  groups: readonly IrmAlertGroup[],
): IrmHeartbeat {
  const latest = groups
    .filter(
      (group) =>
        group.integrationId === integrationId && group.title.trim() === heartbeatMissingTitle,
    )
    .toSorted((a, b) => b.createdAt.getTime() - a.createdAt.getTime())[0];
  if (latest === undefined) {
    return { status: "receiving", lastMissed: null };
  }
  // Acknowledged or silenced, the heartbeat is still missing: only IRM resolves the group.
  if (latest.state !== "resolved") {
    return { status: "missing", since: latest.createdAt };
  }
  return {
    status: "receiving",
    lastMissed:
      latest.resolvedAt === null ? null : { from: latest.createdAt, to: latest.resolvedAt },
  };
}
