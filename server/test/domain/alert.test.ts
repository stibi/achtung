import { describe, expect, it } from "vitest";
import { parseSeverity } from "../../src/domain/alert.ts";

describe("parseSeverity", () => {
  it.each([
    ["critical", "critical"],
    [" Warning ", "warning"],
    ["INFO", "info"],
    ["page", "unknown"],
    [undefined, "unknown"],
  ] as const)("maps %j to %s", (input, expected) => {
    expect(parseSeverity(input)).toBe(expected);
  });
});
