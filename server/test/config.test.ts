import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.ts";

describe("loadConfig", () => {
  const databaseUrl = "postgres://achtung:secret@db.example.com:5432/achtung";

  it("uses defaults for everything but the database", () => {
    expect(loadConfig({ DATABASE_URL: databaseUrl })).toEqual({
      host: "0.0.0.0",
      port: 8080,
      logLevel: "info",
      databaseUrl,
    });
  });

  it("requires a Postgres database URL", () => {
    expect(() => loadConfig({})).toThrow(/DATABASE_URL/);
    expect(() => loadConfig({ DATABASE_URL: "mysql://db.example.com/achtung" })).toThrow(
      /DATABASE_URL/,
    );
  });

  it("fails fast on invalid values", () => {
    expect(() => loadConfig({ DATABASE_URL: databaseUrl, PORT: "not-a-port" })).toThrow(/PORT/);
  });
});
