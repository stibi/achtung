import type {
  FastifyBaseLogger,
  FastifyInstance,
  RawReplyDefaultExpression,
  RawRequestDefaultExpression,
  RawServerDefault,
} from "fastify";
import type { ZodTypeProvider } from "fastify-type-provider-zod";
import { z } from "zod";
import { type ChannelSlug, parseChannelSlug } from "../domain/channel.ts";
import type {
  ChannelOccurrencePage,
  ChannelOverview,
  ListPosition,
  OccurrenceDetail,
  OccurrenceFilter,
  OccurrencePage,
} from "../services/inbox.ts";
import {
  channelListBody,
  errorBody,
  occurrenceDetailBody,
  occurrencePageBody,
  toChannelBody,
  toOccurrenceBody,
  toOccurrenceDetailBody,
} from "./api-schemas.ts";

/** The read side of the inbox, as the client API needs it. */
export interface Inbox {
  listChannels(): Promise<ChannelOverview[]>;
  listChannelOccurrences(
    slug: ChannelSlug,
    filter: OccurrenceFilter,
  ): Promise<ChannelOccurrencePage>;
  listOccurrences(filter: OccurrenceFilter): Promise<OccurrencePage>;
  getOccurrence(id: number): Promise<OccurrenceDetail | null>;
}

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
  const api = app.withTypeProvider<ZodTypeProvider>();
  registerChannelRoutes(api, inbox);
  registerOccurrenceRoutes(api, inbox);
}

type Api = FastifyInstance<
  RawServerDefault,
  RawRequestDefaultExpression,
  RawReplyDefaultExpression,
  FastifyBaseLogger,
  ZodTypeProvider
>;

function registerChannelRoutes(api: Api, inbox: Inbox): void {
  api.get(
    "/api/channels",
    {
      schema: {
        tags: tags(),
        operationId: "listChannels",
        summary: "All channels, by name, with what is firing in each",
        response: { 200: channelListBody },
      },
    },
    async () => ({ channels: (await inbox.listChannels()).map(toChannelBody) }),
  );

  api.get(
    "/api/channels/:slug/occurrences",
    {
      schema: {
        tags: tags(),
        operationId: "listChannelOccurrences",
        summary: "A channel's occurrences, most recently changed first",
        params: z.object({ slug: z.string() }),
        querystring: listQuery,
        response: {
          200: occurrencePageBody,
          400: errorBody,
          404: errorBody,
        },
      },
    },
    async (request, reply) => {
      const filter = filterFrom(request.query);
      if (filter === null) {
        return reply.code(400).send(invalidCursor);
      }
      const slug = parseChannelSlug(request.params.slug);
      const page =
        slug === null
          ? ({ found: false } as const)
          : await inbox.listChannelOccurrences(slug, filter);
      if (!page.found) {
        return reply.code(404).send(notFound("Channel"));
      }
      return toPageBody(page);
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
