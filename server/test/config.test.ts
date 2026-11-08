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
      alertmanagers: new Map(),
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

  it("reads each instance's Alertmanager, with optional basic auth", () => {
    const config = loadConfig({
      DATABASE_URL: databaseUrl,
      ALERTMANAGERS: JSON.stringify({
        onprem: { url: "http://alertmanager.monitoring.svc:9093" },
        edge: { url: "https://alertmanager.example.com/", username: "achtung", password: "pw" },
      }),
    });

    expect(config.alertmanagers).toEqual(
      new Map([
        ["onprem", { url: "http://alertmanager.monitoring.svc:9093", basicAuth: null }],
        [
          "edge",
          {
            url: "https://alertmanager.example.com/",
            basicAuth: { username: "achtung", password: "pw" },
          },
        ],
      ]),
    );
  });

  it.each([
    ["not JSON", "{onprem"],
    ["an invalid instance name", JSON.stringify({ Onprem: { url: "http://am:9093" } })],
    ["a URL that is not HTTP", JSON.stringify({ onprem: { url: "ftp://am" } })],
    [
      "a username without a password",
      JSON.stringify({ onprem: { url: "http://am", username: "a" } }),
    ],
    ["an unknown field", JSON.stringify({ onprem: { url: "http://am", token: "t" } })],
    ["credentials in the URL", JSON.stringify({ onprem: { url: "http://a:s3cret@am:9093" } })],
    ["a URL that is not a URL", JSON.stringify({ onprem: { url: "not a url" } })],
  ])("rejects ALERTMANAGERS with %s", (_, value) => {
    expect(() => loadConfig({ DATABASE_URL: databaseUrl, ALERTMANAGERS: value })).toThrow(
      /ALERTMANAGERS/,
    );
  });

  it("never puts a password in its error", () => {
    const value = JSON.stringify({
      onprem: { url: "ftp://am", username: "a", password: "s3cret" },
    });
    expect(() => loadConfig({ DATABASE_URL: databaseUrl, ALERTMANAGERS: value })).toThrow(
      expect.not.objectContaining({ message: expect.stringContaining("s3cret") }),
    );
  });
});
