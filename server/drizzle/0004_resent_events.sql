-- Edited by hand: the UPDATE backfills last_event_kind from each occurrence's newest
-- recorded event (an occurrence without events keeps the default, fired). It can't use
-- 'resent': a new enum value is only usable once this transaction has committed.
ALTER TYPE "public"."event_kind" ADD VALUE 'resent';--> statement-breakpoint
ALTER TABLE "occurrences" ADD COLUMN "last_event_kind" "event_kind" DEFAULT 'fired' NOT NULL;--> statement-breakpoint
UPDATE "occurrences" SET "last_event_kind" = "latest"."kind"
FROM (
  SELECT DISTINCT ON ("occurrence_id") "occurrence_id", "kind"
  FROM "events"
  ORDER BY "occurrence_id", "recorded_at" DESC, "id" DESC
) AS "latest"
WHERE "latest"."occurrence_id" = "occurrences"."id";
