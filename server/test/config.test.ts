import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.ts";

describe("loadConfig", () => {
  it("uses defaults for an empty environment", () => {
    expect(loadConfig({})).toEqual({ host: "0.0.0.0", port: 8080, logLevel: "info" });
  });

  it("fails fast on invalid values", () => {
    expect(() => loadConfig({ PORT: "not-a-port" })).toThrow(/PORT/);
  });
});
