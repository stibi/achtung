#!/usr/bin/env bash
# Enforces Conventional Commits on the subject line: type(scope)!: description
set -euo pipefail

subject=$(head -n 1 "$1")
pattern='^(feat|fix|docs|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9-]+\))?!?: .{1,72}$'

if [[ "$subject" =~ ^(Merge|Revert\ \"|fixup!\ |squash!\ |amend!\ ) ]] || [[ "$subject" =~ $pattern ]]; then
  exit 0
fi

cat >&2 <<MSG
Commit subject is not a Conventional Commit:
  $subject
Expected: <type>(<scope>): <description>   e.g. feat(server): ingest alertmanager webhooks
Types: feat fix docs refactor perf test build ci chore revert. Scopes: server, macos, api, deploy, docs.
MSG
exit 1
