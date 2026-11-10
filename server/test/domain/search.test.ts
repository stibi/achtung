import { describe, expect, it } from "vitest";
import { parseLabelFilter } from "../../src/domain/search.ts";

describe("parseLabelFilter", () => {
  it("splits name=value at the first =", () => {
    expect(parseLabelFilter("namespace=payments")).toEqual({
      name: "namespace",
      value: "payments",
    });
    expect(parseLabelFilter("query=a=b")).toEqual({ name: "query", value: "a=b" });
    expect(parseLabelFilter("pod=")).toEqual({ name: "pod", value: "" });
  });

  it("is null without a name or an =", () => {
    expect(parseLabelFilter("namespace")).toBeNull();
    expect(parseLabelFilter("=payments")).toBeNull();
    expect(parseLabelFilter("")).toBeNull();
  });
});
