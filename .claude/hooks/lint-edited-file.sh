#!/usr/bin/env bash
# PostToolUse hook: format and lint each file Claude edits, and report remaining problems
# back to Claude right away (exit 2 shows stderr to Claude; the edit itself stays).
set -euo pipefail

file=$(jq -r '.tool_input.file_path // empty')
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

case "$file" in
  "$root"/server/*.ts | "$root"/server/*.json | "$root"/server/*.cjs | "$root"/server/*.mjs) ;;
  *) exit 0 ;;
esac
[[ -f "$file" ]] || exit 0

cd "$root/server"
if ! output=$(pnpm exec biome check --write --no-errors-on-unmatched "$file" 2>&1); then
  printf 'Biome found problems in %s. Fix them:\n%s\n' "$file" "$output" >&2
  exit 2
fi
