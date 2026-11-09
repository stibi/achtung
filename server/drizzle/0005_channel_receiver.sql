ALTER TABLE "channels" ADD COLUMN "receiver" text;--> statement-breakpoint
CREATE INDEX "events_recorded_at" ON "events" USING btree ("recorded_at");