// Architecture rules for the server. Layers and the reasoning are in docs/architecture.md.
// Each `comment` is printed on violation: it tells the agent how to fix the code, so keep
// it actionable.

/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: "domain-is-pure",
      severity: "error",
      comment:
        "src/domain is the pure core: types and logic only, no I/O, no libraries, no other " +
        "layers. Move the code that needs them into a service or adapter, and pass plain data " +
        "into the domain.",
      from: { path: "^src/domain/" },
      to: { pathNot: "^src/domain/" },
    },
    {
      name: "sources-only-use-domain",
      severity: "error",
      comment:
        "Source adapters only translate payloads into domain types. They may import " +
        "src/domain, src/sources/source-adapter.ts, their own folder and zod. Storage, HTTP " +
        "and services must call adapters, not the other way round.",
      from: { path: "^src/sources/" },
      to: {
        dependencyTypesNot: ["npm"],
        pathNot: ["^src/domain/", "^src/sources/"],
      },
    },
    {
      name: "sources-npm-only-zod",
      severity: "error",
      comment:
        "Source adapters may only use zod from npm. If an adapter needs more, discuss it and " +
        "update this rule together with docs/architecture.md.",
      from: { path: "^src/sources/" },
      to: { dependencyTypes: ["npm"], pathNot: "node_modules/zod/" },
    },
    {
      name: "no-cross-adapter-imports",
      severity: "error",
      comment:
        "Source adapters must be independent of each other. Move shared code into " +
        "src/sources/ (next to source-adapter.ts) or into src/domain.",
      from: { path: "^src/sources/([^/]+)/" },
      to: { path: "^src/sources/[^/]+/", pathNot: "^src/sources/$1/" },
    },
    {
      name: "adapter-public-api-is-index",
      severity: "error",
      comment:
        "Outside an adapter's folder, import it only through its index.ts " +
        "(e.g. src/sources/alertmanager/index.ts). Export what you need from there.",
      from: { pathNot: "^src/sources/" },
      to: { path: "^src/sources/[^/]+/", pathNot: "^src/sources/[^/]+/index\\.ts$" },
    },
    {
      name: "config-is-leaf",
      severity: "error",
      comment:
        "src/config.ts only parses the environment. It must not import application code; " +
        "pass config values into the modules that need them.",
      from: { path: "^src/config\\.ts$" },
      to: { path: "^src/", pathNot: "^src/config\\.ts$" },
    },
    {
      name: "main-is-composition-root",
      severity: "error",
      comment:
        "src/main.ts wires the application together and nothing may import it. Move the " +
        "shared code into its layer and import it from there.",
      from: {},
      to: { path: "^src/main\\.ts$" },
    },
    {
      name: "no-circular",
      severity: "error",
      comment:
        "Circular dependency. Usually one of the modules belongs in a lower layer, or the " +
        "shared part should be extracted into it.",
      from: {},
      to: { circular: true },
    },
    {
      name: "no-orphans",
      severity: "error",
      comment:
        "This module is not imported by anything. Delete it, or wire it in where it belongs.",
      from: { orphan: true, pathNot: ["^src/main\\.ts$", "\\.d\\.ts$"] },
      to: {},
    },
    {
      name: "no-dev-dependencies-in-src",
      severity: "error",
      comment:
        "Production code must not import devDependencies. Add it as a dependency, or move the code to test/.",
      from: { path: "^src/" },
      to: { dependencyTypes: ["npm-dev"] },
    },
    {
      name: "not-to-unresolvable",
      severity: "error",
      comment:
        "This import cannot be resolved. Check the path (relative imports need the .ts extension).",
      from: {},
      to: { couldNotResolve: true },
    },
  ],
  options: {
    doNotFollow: { path: "node_modules" },
    tsConfig: { fileName: "tsconfig.json" },
    tsPreCompilationDeps: true,
    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "node", "default", "types"],
    },
    reporterOptions: { text: { highlightFocused: true } },
  },
};
