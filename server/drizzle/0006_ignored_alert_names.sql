-- Edited by hand: the INSERT seeds the list with what the Home view left out before it was
-- configurable (Watchdog, InfoInhibitor), plus Grafana IRM's heartbeat (ADR 0011).
CREATE TABLE "ignored_alert_names" (
	"name" text PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
INSERT INTO "ignored_alert_names" ("name", "created_at")
VALUES ('Watchdog', now()), ('InfoInhibitor', now()), ('grafana-irm-heartbeat', now());
