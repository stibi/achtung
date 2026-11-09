import { describe, expect, it } from "vitest";
import {
  isActive,
  type LabelMatcher,
  matchersFor,
  type Silence,
  silencedUntil,
} from "../../src/domain/silence.ts";

const labels = { alertname: "TargetDown", namespace: "example-prod", severity: "warning" };
const now = new Date("2026-10-13T10:00:00Z");

function silence(
  matchers: LabelMatcher[],
  endsAt = "2026-10-13T11:00:00Z",
  startsAt = "2026-10-13T09:00:00Z",
): Silence {
  return {
    id: "s",
    matchers,
    startsAt: new Date(startsAt),
    endsAt: new Date(endsAt),
    createdBy: "someone",
    comment: "maintenance",
  };
}

const equal = (name: string, value: string): LabelMatcher => ({
  name,
  value,
  isRegex: false,
  isEqual: true,
});

describe("matchersFor", () => {
  it("matches every label exactly, in name order", () => {
    expect(matchersFor({ severity: "warning", alertname: "TargetDown" })).toEqual([
      equal("alertname", "TargetDown"),
      equal("severity", "warning"),
    ]);
  });
});

describe("silencedUntil", () => {
  it("is the end of a silence matching every label", () => {
    expect(silencedUntil(labels, [silence(matchersFor(labels))], now)).toEqual(
      new Date("2026-10-13T11:00:00Z"),
    );
  });

  it("is null without a matching silence", () => {
    expect(silencedUntil(labels, [], now)).toBeNull();
    expect(silencedUntil(labels, [silence([equal("namespace", "other")])], now)).toBeNull();
  });

  it("counts a silence on fewer labels, which mutes more alerts", () => {
    expect(
      silencedUntil(labels, [silence([equal("namespace", "example-prod")])], now),
    ).not.toBeNull();
  });

  it("needs every matcher to match", () => {
    const matchers = [equal("namespace", "example-prod"), equal("alertname", "Other")];
    expect(silencedUntil(labels, [silence(matchers)], now)).toBeNull();
  });

  it("treats a missing label as empty, as Alertmanager does", () => {
    expect(silencedUntil(labels, [silence([equal("team", "")])], now)).not.toBeNull();
    expect(silencedUntil(labels, [silence([equal("team", "ops")])], now)).toBeNull();
  });

  it("anchors a regex to the whole value", () => {
    const regex = (value: string): LabelMatcher[] => [
      { name: "namespace", value, isRegex: true, isEqual: true },
    ];
    expect(silencedUntil(labels, [silence(regex("example-.*"))], now)).not.toBeNull();
    expect(silencedUntil(labels, [silence(regex("example"))], now)).toBeNull();
    expect(silencedUntil(labels, [silence(regex("prod|example-prod"))], now)).not.toBeNull();
  });

  it("negates a matcher that is not equal", () => {
    const notEqual = (value: string): LabelMatcher[] => [
      { name: "namespace", value, isRegex: false, isEqual: false },
    ];
    expect(silencedUntil(labels, [silence(notEqual("other"))], now)).not.toBeNull();
    expect(silencedUntil(labels, [silence(notEqual("example-prod"))], now)).toBeNull();
  });

  it("never matches a regex JavaScript can't compile", () => {
    const matchers = [
      { name: "namespace", value: "(?i)EXAMPLE-PROD", isRegex: true, isEqual: true },
    ];
    expect(silencedUntil(labels, [silence(matchers)], now)).toBeNull();
  });

  it("never matches a negated regex JavaScript can't compile", () => {
    const matchers = [{ name: "namespace", value: "(?i)OTHER", isRegex: true, isEqual: false }];
    expect(silencedUntil(labels, [silence(matchers)], now)).toBeNull();
  });

  it("ignores a silence that has ended or not started", () => {
    const matchers = matchersFor(labels);
    expect(silencedUntil(labels, [silence(matchers, "2026-10-13T10:00:00Z")], now)).toBeNull();
    expect(
      silencedUntil(
        labels,
        [silence(matchers, "2026-10-13T12:00:00Z", "2026-10-13T10:00:01Z")],
        now,
      ),
    ).toBeNull();
  });

  it("is the latest end when several silences match", () => {
    const matchers = matchersFor(labels);
    const silences = [
      silence(matchers, "2026-10-13T11:00:00Z"),
      silence(matchers, "2026-10-14T10:00:00Z"),
      silence(matchers, "2026-10-13T12:00:00Z"),
    ];
    expect(silencedUntil(labels, silences, now)).toEqual(new Date("2026-10-14T10:00:00Z"));
  });
});

describe("isActive", () => {
  it("is active from its start until just before its end", () => {
    const window = silence([], "2026-10-13T11:00:00Z", "2026-10-13T09:00:00Z");

    expect(isActive(window, new Date("2026-10-13T08:59:59.999Z"))).toBe(false);
    expect(isActive(window, new Date("2026-10-13T09:00:00Z"))).toBe(true);
    expect(isActive(window, new Date("2026-10-13T10:59:59.999Z"))).toBe(true);
    expect(isActive(window, new Date("2026-10-13T11:00:00Z"))).toBe(false);
  });
});
