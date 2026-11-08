import { describe, expect, it } from "vitest";
import { eventFor, resendQuietPeriodMs } from "../../src/domain/occurrence.ts";

const now = new Date("2026-10-13T12:00:00Z");
const ago = (ms: number) => new Date(now.getTime() - ms);
const minute = 60 * 1000;

describe("eventFor", () => {
  it.each([
    [null, "firing", "fired"],
    [null, "resolved", "resolved"],
    ["firing", "resolved", "resolved"],
    ["resolved", "firing", "reopened"],
  ] as const)("%s + %s notification → %s", (current, incoming, expected) => {
    const state = current === null ? null : { status: current, lastEventAt: ago(minute) };
    expect(eventFor(state, incoming, now)).toBe(expected);
  });

  it("treats a repeat within the quiet period as nothing new", () => {
    const firing = { status: "firing", lastEventAt: ago(resendQuietPeriodMs - 1) } as const;
    expect(eventFor(firing, "firing", now)).toBeNull();
  });

  it("counts a repeat of a firing alert after the quiet period as resent", () => {
    expect(resendQuietPeriodMs).toBe(60 * minute);
    const firing = { status: "firing", lastEventAt: ago(resendQuietPeriodMs) } as const;
    expect(eventFor(firing, "firing", now)).toBe("resent");
  });

  it("never resends a resolved alert", () => {
    const resolved = { status: "resolved", lastEventAt: ago(10 * resendQuietPeriodMs) } as const;
    expect(eventFor(resolved, "resolved", now)).toBeNull();
  });
});
