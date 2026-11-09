import type { FastifyInstance } from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import { z } from "zod";
import { type InstanceName, parseChannelSlug, parseInstanceName } from "../domain/channel.ts";
import type { ListPosition, OccurrenceFilter, OccurrencePage } from "../services/inbox.ts";
import type { Api, Inbox } from "./api-contract.ts";
import {
  channelListBody,
  errorBody,
  occurrenceDetailBody,
  occurrencePageBody,
  toChannelBody,
  toOccurrenceBody,
  toOccurrenceDetailBody,
} from "./api-schemas.ts";
import { registerHomeRoute } from "./home.ts";
import { registerSilenceRoutes } from "./silence.ts";

export type { Inbox } from "./api-contract.ts";

// A fresh array per route: a shared one becomes YAML anchors in api/openapi.yaml.
const tags = () => ["client"];
const notFound = (what: string) => ({ error: `${what} not found` });

// The cursor is opaque to clients: a base64url-encoded [lastEventAt, id] pair.
function encodeCursor(position: ListPosition): string {
  return Buffer.from(JSON.stringify([position.lastEventAt.toISOString(), position.id])).toString(
    "base64url",
  );
}

const cursorPayload = z.tuple([z.iso.datetime({ offset: true }), z.int().positive()]);

function decodeCursor(cursor: string): ListPosition | null {
  try {
    const parsed = cursorPayload.safeParse(JSON.parse(Buffer.from(cursor, "base64url").toString()));
    return parsed.success ? { lastEventAt: new Date(parsed.data[0]), id: parsed.data[1] } : null;
  } catch {
    // Not JSON at all: the same as any other cursor this server never issued.
    return null;
  }
}

// Shared by both occurrence lists, so they page and filter the same way.
const listQuery = z.object({
  status: z.enum(["firing", "resolved"]).optional(),
  cursor: z.string().optional().describe("nextCursor from the previous page"),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});

/** The filter a list query asks for; null when its cursor is not one this server issued. */
function filterFrom({
  status,
  cursor,
  limit,
}: z.output<typeof listQuery>): OccurrenceFilter | null {
  const after = cursor === undefined ? null : decodeCursor(cursor);
  if (after === null && cursor !== undefined) {
    return null;
  }
  return { status: status ?? null, after, limit };
}

const invalidCursor = { error: "Invalid cursor" };

function toPageBody(page: OccurrencePage) {
  return {
    occurrences: page.occurrences.map(toOccurrenceBody),
    nextCursor: page.next === null ? null : encodeCursor(page.next),
  };
}

export function registerApiRoutes(app: FastifyInstance, inbox: Inbox): void {
  // Its own plugin, so the hook covers these routes only.
  app.register(async (scope) => {
    // An inbox is stale the moment it is stored: no client or proxy should cache it.
    scope.addHook("onRequest", async (_request, reply) => {
      reply.header("cache-control", "no-store");
    });
    const api = scope.withTypeProvider<ZodTypeProvider>();
    registerChannelRoutes(api, inbox);
    registerOccurrenceRoutes(api, inbox);
    registerSilenceRoutes(api, inbox);
    registerHomeRoute(api, inbox);
  });
}

type Failure = { readonly code: 400 | 404; readonly body: { readonly error: string } };

/** A channel's page, or why there is none. */
async function channelPage(
  inbox: Inbox,
  instance: InstanceName | null,
  name: string,
  query: z.output<typeof listQuery>,
): Promise<ReturnType<typeof toPageBody> | Failure> {
  const filter = filterFrom(query);
  if (filter === null) {
    return { code: 400, body: invalidCursor };
  }
  const slug = parseChannelSlug(name);
  const page =
    slug === null
      ? ({ found: false } as const)
      : await inbox.listChannelOccurrences({ instance, slug }, filter);
  return page.found ? toPageBody(page) : channelNotFound;
}

const channelNotFound: Failure = { code: 404, body: notFound("Channel") };

function registerChannelRoutes(api: Api, inbox: Inbox): void {
  api.get(
    "/api/channels",
    {
      schema: {
        tags: tags(),
        operationId: "listChannels",
        summary: "All channels, by instance and name, with what is firing in each",
        response: { 200: channelListBody },
      },
    },
    async () => ({ channels: (await inbox.listChannels()).map(toChannelBody) }),
  );

  const response = { 200: occurrencePageBody, 400: errorBody, 404: errorBody };
  api.get(
    "/api/instances/:instance/channels/:slug/occurrences",
    {
      schema: {
        tags: tags(),
        operationId: "listInstanceChannelOccurrences",
        summary: "A channel's occurrences, most recently changed first",
        params: z.object({ instance: z.string(), slug: z.string() }),
        querystring: listQuery,
        response,
      },
    },
    async (request, reply) => {
      const instance = parseInstanceName(request.params.instance);
      const result =
        instance === null
          ? channelNotFound
          : await channelPage(inbox, instance, request.params.slug, request.query);
      return "code" in result ? reply.code(result.code).send(result.body) : result;
    },
  );

  api.get(
    "/api/channels/:slug/occurrences",
    {
      schema: {
        tags: tags(),
        operationId: "listChannelOccurrences",
        summary:
          "A channel's occurrences, by name only. Deprecated: use the route with an instance.",
        description:
          "The name resolves to the one named instance's channel of that name, else to the default instance's.",
        // Deprecated in words only: the flag would make the generated Swift method deprecated,
        // and the client builds with warnings as errors.
        params: z.object({ slug: z.string() }),
        querystring: listQuery,
        response,
      },
    },
    async (request, reply) => {
      const result = await channelPage(inbox, null, request.params.slug, request.query);
      return "code" in result ? reply.code(result.code).send(result.body) : result;
    },
  );
}

function registerOccurrenceRoutes(api: Api, inbox: Inbox): void {
  api.get(
    "/api/occurrences",
    {
      schema: {
        tags: tags(),
        operationId: "listOccurrences",
        summary: "Every channel's occurrences in one list, most recently changed first",
        querystring: listQuery,
        response: { 200: occurrencePageBody, 400: errorBody },
      },
    },
    async (request, reply) => {
      const filter = filterFrom(request.query);
      if (filter === null) {
        return reply.code(400).send(invalidCursor);
      }
      return toPageBody(await inbox.listOccurrences(filter));
    },
  );

  api.get(
    "/api/occurrences/:id",
    {
      schema: {
        tags: tags(),
        operationId: "getOccurrence",
        summary: "One occurrence with its history and the alert's other occurrences",
        params: z.object({ id: z.coerce.number().int().positive() }),
        response: { 200: occurrenceDetailBody, 400: errorBody, 404: errorBody },
      },
    },
    async (request, reply) => {
      const detail = await inbox.getOccurrence(request.params.id);
      if (detail === null) {
        return reply.code(404).send(notFound("Occurrence"));
      }
      return toOccurrenceDetailBody(detail);
    },
  );
}
