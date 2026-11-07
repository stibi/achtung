#!/usr/bin/env bash
# Fails when src/db/schema.ts has changes that no committed migration covers.
# Generates into a scratch copy of drizzle/, so the working tree is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

# drizzle-kit only accepts a relative --out path.
scratch="$(mktemp -d .migrations-check.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
cp -R drizzle/. "$scratch"

# drizzle-kit exits 0 even when it fails, so judge it by what it prints, never by the exit
# code. Keep these flags in sync with drizzle.config.ts (a config file can't redirect --out).
output="$(pnpm exec drizzle-kit generate --dialect postgresql --casing snake_case \
  --schema src/db/schema.ts --out "$scratch" --name pending 2>&1)" || true

if grep -q "No schema changes" <<<"$output"; then
  exit 0
fi
if grep -q "Your SQL migration file" <<<"$output"; then
  echo "src/db/schema.ts changed, but no migration covers it." >&2
  echo "Run \`pnpm run db:generate\` and commit the new file in server/drizzle/." >&2
else
  echo "Could not compare the schema with the migrations:" >&2
  echo "$output" >&2
fi
exit 1
