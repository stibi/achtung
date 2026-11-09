import { describe, expect, it } from "vitest";
import { parseSeverity, summaryOf } from "../../src/domain/alert.ts";

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

describe("summaryOf", () => {
  it("is the summary annotation, before the description", () => {
    expect(summaryOf({ summary: "Disk full", description: "Long text" })).toBe("Disk full");
  });

  it("falls back to the description", () => {
    expect(summaryOf({ description: "Long text" })).toBe("Long text");
  });

  it("is null without either", () => {
    expect(summaryOf({ runbook_url: "https://runbooks.example/disk" })).toBeNull();
  });
});
