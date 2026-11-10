CREATE TYPE "public"."event_cause" AS ENUM('vanished');--> statement-breakpoint
ALTER TABLE "events" ADD COLUMN "cause" "event_cause";