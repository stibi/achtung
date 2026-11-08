/** A channel's name as it appears in the ingest URL, e.g. `crm-prod`. Only parsed slugs exist. */
export type ChannelSlug = string & { readonly brand: "ChannelSlug" };

/**
 * The name of the system that sends to a channel, e.g. `onprem` for one cluster's
 * Alertmanager. Channels are grouped under it, and a channel name is unique only within it.
 */
export type InstanceName = string & { readonly brand: "InstanceName" };

/** Lowercase letters, digits and dashes, starting with a letter or digit, at most 63 long. */
export const channelSlugRule = "^[a-z0-9][a-z0-9-]{0,62}$";
const pattern = new RegExp(channelSlugRule);

export function parseChannelSlug(value: string): ChannelSlug | null {
  return pattern.test(value) ? (value as ChannelSlug) : null;
}

/** Instance names follow the channel name rule. */
export function parseInstanceName(value: string): InstanceName | null {
  return pattern.test(value) ? (value as InstanceName) : null;
}

/**
 * Where the old URLs without an instance (/ingest/{source}/{channel}) create channels they
 * have never seen. A name they have seen resolves to its channel, in whatever instance.
 */
const defaultInstance = "default" as InstanceName;

/** A channel, fully named. */
export interface ChannelRef {
  readonly instance: InstanceName;
  readonly slug: ChannelSlug;
}

/** A channel as a request names it; `instance` is null on the old URLs that have none. */
export interface ChannelAddress {
  readonly instance: InstanceName | null;
  readonly slug: ChannelSlug;
}

/**
 * The channel an address means. Without an instance, a name resolves to the one named
 * instance that has a channel of that name, so a stray `default` copy never takes over.
 * A name no named instance has, or several have, means the default instance's channel.
 */
export function resolveChannel(
  { instance, slug }: ChannelAddress,
  instancesWithName: readonly InstanceName[],
): ChannelRef {
  if (instance !== null) {
    return { instance, slug };
  }
  const [only, ...others] = instancesWithName.filter((name) => name !== defaultInstance);
  return { instance: only !== undefined && others.length === 0 ? only : defaultInstance, slug };
}
