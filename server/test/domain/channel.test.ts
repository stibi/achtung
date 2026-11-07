import { describe, expect, it } from "vitest";
import { parseChannelSlug } from "../../src/domain/channel.ts";

describe("parseChannelSlug", () => {
  it.each(["crm-prod", "a", "0-legacy", "a".repeat(63)])("accepts %s", (value) => {
    expect(parseChannelSlug(value)).toBe(value);
  });

  it.each(["", "Crm-Prod", "-prod", "crm_prod", "crm prod", "a".repeat(64), "crm/prod"])(
    "rejects %j",
    (value) => {
      expect(parseChannelSlug(value)).toBeNull();
    },
  );
});
