/** A channel's name as it appears in the ingest URL, e.g. `crm-prod`. Only parsed slugs exist. */
export type ChannelSlug = string & { readonly brand: "ChannelSlug" };

/** Lowercase letters, digits and dashes, starting with a letter or digit, at most 63 long. */
export const channelSlugRule = "^[a-z0-9][a-z0-9-]{0,62}$";
const pattern = new RegExp(channelSlugRule);

export function parseChannelSlug(value: string): ChannelSlug | null {
  return pattern.test(value) ? (value as ChannelSlug) : null;
}
