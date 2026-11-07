-- Edited by hand: the UPDATE backfills occurrences that existed before the column (the
-- ADD COLUMN gave them now()). An occurrence's first event is its insert, so one with no
-- recorded events falls back to first_received_at.
ALTER TABLE "occurrences" ADD COLUMN "last_event_at" timestamp with time zone DEFAULT now() NOT NULL;--> statement-breakpoint
UPDATE "occurrences" SET "last_event_at" = coalesce(
  (SELECT max("recorded_at") FROM "events" WHERE "events"."occurrence_id" = "occurrences"."id"),
  "occurrences"."first_received_at"
);--> statement-breakpoint
CREATE INDEX "occurrences_channel_last_event" ON "occurrences" USING btree ("channel_id","last_event_at" DESC NULLS LAST,"id" DESC NULLS LAST);
