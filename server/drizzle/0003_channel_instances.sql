ALTER TABLE "channels" DROP CONSTRAINT "channels_slug_unique";--> statement-breakpoint
ALTER TABLE "channels" ADD COLUMN "instance" text DEFAULT 'default' NOT NULL;--> statement-breakpoint
ALTER TABLE "channels" ADD CONSTRAINT "channels_instance_slug" UNIQUE("instance","slug");