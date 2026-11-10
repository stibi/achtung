import { describe, expect, it } from "vitest";
import { trackAbsences, vanishAfterMs } from "../../src/domain/vanished.ts";

const at = (time: string) => new Date(`2026-10-13T${time}Z`);
const one = { id: 1 };
const two = { id: 2 };

describe("trackAbsences", () => {
  it("starts counting at the first read without the occurrence", () => {
    const { absences, due } = trackAbsences(new Map(), [one], at("10:00:00"));

    expect(absences).toEqual(new Map([[1, at("10:00:00")]]));
    expect(due).toEqual([]);
  });

  it("keeps the first read while it stays gone, and is due after vanishAfterMs exactly", () => {
    const previous = new Map([[1, at("10:00:00")]]);

    expect(trackAbsences(previous, [one], at("10:04:59.999")).due).toEqual([]);
    const { absences, due } = trackAbsences(previous, [one, two], at("10:05:00"));

    expect(vanishAfterMs).toBe(5 * 60 * 1000);
    expect(due).toEqual([{ occurrence: one, since: at("10:00:00") }]);
    expect(absences).toEqual(
      new Map([
        [1, at("10:00:00")],
        [2, at("10:05:00")],
      ]),
    );
  });

  it("forgets one a read has again, so its next absence starts over", () => {
    const previous = new Map([
      [1, at("10:00:00")],
      [2, at("10:00:00")],
    ]);

    const { absences, due } = trackAbsences(previous, [two], at("10:06:00"));

    expect(absences).toEqual(new Map([[2, at("10:00:00")]]));
    expect(due).toEqual([{ occurrence: two, since: at("10:00:00") }]);
  });
});
