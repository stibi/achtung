CREATE TYPE "public"."event_kind" AS ENUM('fired', 'resolved', 'reopened');--> statement-breakpoint
CREATE TYPE "public"."occurrence_status" AS ENUM('firing', 'resolved');--> statement-breakpoint
CREATE TYPE "public"."severity" AS ENUM('critical', 'warning', 'info', 'unknown');--> statement-breakpoint
CREATE TABLE "channels" (
	"id" integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "channels_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1),
	"slug" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	CONSTRAINT "channels_slug_unique" UNIQUE("slug")
);
--> statement-breakpoint
CREATE TABLE "events" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "events_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"occurrence_id" bigint NOT NULL,
	"kind" "event_kind" NOT NULL,
	"recorded_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "occurrences" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "occurrences_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"channel_id" integer NOT NULL,
	"source" text NOT NULL,
	"source_key" text NOT NULL,
	"starts_at" timestamp with time zone NOT NULL,
	"status" "occurrence_status" NOT NULL,
	"ends_at" timestamp with time zone,
	"severity" "severity" NOT NULL,
	"title" text NOT NULL,
	"summary" text,
	"labels" jsonb NOT NULL,
	"annotations" jsonb NOT NULL,
	"links" jsonb NOT NULL,
	"first_received_at" timestamp with time zone NOT NULL,
	"last_received_at" timestamp with time zone NOT NULL,
	"notification_count" integer DEFAULT 1 NOT NULL,
	CONSTRAINT "occurrences_identity" UNIQUE("channel_id","source","source_key","starts_at"),
	CONSTRAINT "occurrences_end_matches_status" CHECK (("occurrences"."status" = 'firing') = ("occurrences"."ends_at" is null))
);
--> statement-breakpoint
ALTER TABLE "events" ADD CONSTRAINT "events_occurrence_id_occurrences_id_fk" FOREIGN KEY ("occurrence_id") REFERENCES "public"."occurrences"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "occurrences" ADD CONSTRAINT "occurrences_channel_id_channels_id_fk" FOREIGN KEY ("channel_id") REFERENCES "public"."channels"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "events_occurrence_id" ON "events" USING btree ("occurrence_id");