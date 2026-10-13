#!/usr/bin/env bash
# Stop hook: Claude may not finish while the server has uncommitted changes that fail
# `pnpm check`. Exit 2 blocks the stop and hands the failure output back to Claude.
# After 3 consecutive blocks in a session the stop is allowed, so Claude can explain a
# problem it can't fix instead of looping. The pre-commit hook and CI still gate it.
set -euo pipefail

input=$(cat)
session=$(jq -r '.session_id // "unknown"' <<<"$input")
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
cd "$root"
counter="$(git rev-parse --git-path "achtung-stop-blocks-$session")"
max_blocks=3

if [[ -z "$(git status --porcelain -- server)" ]] || output=$(pnpm --dir server run check 2>&1); then
  rm -f "$counter"
  exit 0
fi

blocks=$(($(cat "$counter" 2>/dev/null || echo 0) + 1))
if ((blocks > max_blocks)); then
  rm -f "$counter"
  exit 0
fi
echo "$blocks" >"$counter"

{
  echo "pnpm check fails in server/ (block $blocks of $max_blocks). Fix the root cause before"
  echo "finishing; do not disable or weaken checks. If you can't fix it, or a rule is wrong"
  echo "for this case, explain why to the user and stop."
  echo
  printf '%s\n' "$output" | tail -n 80
} >&2
exit 2
