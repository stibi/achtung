import { describe, expect, it } from "vitest";
import { buildApp } from "../../src/http/app.ts";
import { alertmanagerSource } from "../../src/sources/alertmanager/index.ts";
import { unusedServices } from "../app.ts";

// api/openapi.yaml is the client contract; the macOS client is generated from it. This
// fails when the routes changed and the committed file was not regenerated. To update it:
// `pnpm run api:generate`, then review the diff like any API change.
describe("OpenAPI document", () => {
  it("matches the committed api/openapi.yaml", async () => {
    const app = buildApp({
      logLevel: "silent",
      sources: [alertmanagerSource],
      services: unusedServices,
      checkReady: async () => {},
    });
    await app.ready();

    const document = app.swagger({ yaml: true });
    await app.close();

    await expect(document).toMatchFileSnapshot("../../../api/openapi.yaml");
  });
});
