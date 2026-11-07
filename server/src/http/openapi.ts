import type { SwaggerTransformObject } from "@fastify/swagger";
import {
  createJsonSchemaTransform,
  createJsonSchemaTransformObject,
} from "fastify-type-provider-zod";

// How the Zod route schemas become api/openapi.yaml, the contract the macOS client is
// generated from. Two adjustments keep the generated Swift types clean.

interface JsonSchemaNode {
  format?: string;
  pattern?: string;
  additionalProperties?: unknown;
}

const zodToJsonConfig = {
  override: ({ jsonSchema }: { jsonSchema: JsonSchemaNode }) => {
    // Zod adds an RFC 3339 regex next to `format: date-time`. The format already says
    // it, and the regex is unreadable noise in the document.
    if (jsonSchema.format === "date-time") {
      delete jsonSchema.pattern;
    }
    // Zod marks every object closed. The Swift generator then rejects unknown keys, so a
    // field added to a response would break every client not yet regenerated.
    if (jsonSchema.additionalProperties === false) {
      delete jsonSchema.additionalProperties;
    }
  },
};

export const openApiTransform = createJsonSchemaTransform({ zodToJsonConfig });

const withAllSchemas = createJsonSchemaTransformObject({ zodToJsonConfig });

/**
 * Every registered schema is emitted twice, as `X` (response shape) and `XInput` (request
 * shape). Only the ones routes reference are kept, so clients get one type per shape.
 */
export const openApiTransformObject: SwaggerTransformObject = (document) => {
  const full = withAllSchemas(document) as {
    paths?: unknown;
    components?: { schemas?: Record<string, unknown> };
  };
  const schemas = full.components?.schemas ?? {};
  const used = new Set<string>();
  const visit = (value: unknown): void => {
    for (const name of referencedSchemas(value)) {
      if (!used.has(name)) {
        used.add(name);
        visit(schemas[name]);
      }
    }
  };
  visit(full.paths);
  return {
    ...full,
    components: {
      ...full.components,
      schemas: Object.fromEntries(Object.entries(schemas).filter(([name]) => used.has(name))),
    },
  } as ReturnType<SwaggerTransformObject>;
};

function referencedSchemas(value: unknown): string[] {
  const prefix = "#/components/schemas/";
  return [...JSON.stringify(value ?? null).matchAll(/"\$ref":"([^"]+)"/g)]
    .map((match) => match[1] ?? "")
    .filter((ref) => ref.startsWith(prefix))
    .map((ref) => ref.slice(prefix.length));
}
