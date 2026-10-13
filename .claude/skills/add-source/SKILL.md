---
name: add-source
description: Add support for a new alert source (a monitoring system sending webhooks) to the Achtung server.
---
# Add an alert source

The Alertmanager adapter (`server/src/sources/alertmanager/`) is the reference
implementation. Copy its shape, not its contents.

1. **Get real payloads first.** Find the source's webhook documentation and at least one
   real firing payload and one resolved payload. Anonymize them (hostnames, namespaces,
   IPs, tokens → `example.com` / `example-prod`) and save them to
   `server/test/fixtures/<id>/`.
2. **Decide the identity.** Which payload field is the stable identity (`sourceKey`) of
   an alert, and how is an occurrence distinguished (`startsAt`)? If the source has no
   stable identity, stop and ask. Don't invent one.
3. **Write the tests first** in `server/test/sources/<id>.test.ts`: firing maps
   correctly, resolved keeps the same identity, invalid payloads are rejected, and
   missing optional fields fall back sensibly.
4. **Implement** `payload.ts` (Zod schema with a link to the docs), `map.ts` (pure
   mapping to `IncomingAlert`) and `index.ts` (exports the `SourceAdapter`).
5. **If the domain can't express something this source needs**, don't work around it in
   the adapter. Stop, describe the gap, and propose a domain change plus an ADR.
6. Register the adapter in the composition root (`server/src/main.ts`). Until the ingest
   route exists, there is nothing to register with yet. Say so; don't build a registry
   for it. Run `pnpm check`, and add the source to the "Source" row of the concepts
   table in `README.md`.
