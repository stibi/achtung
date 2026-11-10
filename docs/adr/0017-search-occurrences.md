# 0017: Search occurrences across channels

- Status: accepted
- Date: 2026-11-10

## Context

The client shows occurrences per channel and in one feed, newest change first, but
can't find an alert by what it is: its name, a word of its summary, or a label such as
`namespace=payments` across every channel and instance. The user wants that.

## Decision

- **The occurrence lists take search parameters**, both `GET /api/occurrences` and a
  channel's list, so search pages and orders like the lists themselves (the same cursor):
  - `q`: text found, ignoring case and taken literally (`%` and `_` are no wildcards), in
    the title, the summary, or the labels' names and values;
  - `label=name=value`, repeatable: each label must have exactly that value (split at the
    first `=`, so a value may contain one);
  - `severity`, repeatable: any of them;
  - `instance`: only that instance;
  - combined with each other and with `status`, all must match.
- **Postgres does the matching**, with `ILIKE` and JSON containment (`labels @> …`),
  in `db/search.ts`. Label names and values are matched as they are
  (`jsonb_each_text`), not as JSON escapes them, so quotes and backslashes are found.
- **Parsed at the boundary:** a NUL (which Postgres text can't hold), a label filter
  that isn't `name=value` and an invalid instance name are a 400, never a database error.
- **No index for now.** Production holds some hundreds of occurrences, and a scan of a
  few thousand rows is cheap. A GIN index on `labels` (and `pg_trgm` for the text) is the
  step when that changes.
- No regex matching and no full-text ranking: exact labels plus a substring cover
  finding an alert, and keep the parameters predictable.

## Consequences

- The client can build a search field over the feed and the channels, with label
  chips turning into `label=` filters.
- The search costs a sequential scan per page; with paging by `(lastEventAt, id)` it
  stops at the page's end once enough rows match, but a rare match scans everything.
