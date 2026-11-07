import { defineConfig } from "drizzle-kit";

// Used only by `pnpm run db:generate`, which diffs the schema against the committed
// migrations and writes a new one. Needs no database connection. scripts/check-migrations.sh
// repeats these settings as flags; change both together.
export default defineConfig({
  dialect: "postgresql",
  casing: "snake_case",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
});
