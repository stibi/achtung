import { describe, expect, it } from "vitest";
import { eventFor } from "../../src/domain/occurrence.ts";

describe("eventFor", () => {
  it.each([
    [null, "firing", "fired"],
    [null, "resolved", "resolved"],
    ["firing", "firing", null],
    ["firing", "resolved", "resolved"],
    ["resolved", "resolved", null],
    ["resolved", "firing", "reopened"],
  ] as const)("%s + %s notification → %s", (current, incoming, expected) => {
    expect(eventFor(current, incoming)).toBe(expected);
  });
});
