import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // Starts Postgres in Docker once per run (Testcontainers). See test/database.ts.
    globalSetup: ["test/global-setup.ts"],
    coverage: {
      include: ["src/**"],
      exclude: ["src/main.ts"],
    },
  },
});
