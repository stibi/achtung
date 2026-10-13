// Mutation testing checks that the tests actually catch bugs. It is slow, so it runs
// nightly in CI and only covers the pure core: domain logic and source adapters.
export default {
  testRunner: "vitest",
  // pnpm does not hoist packages, so Stryker cannot discover the runner by itself.
  plugins: ["@stryker-mutator/vitest-runner"],
  mutate: ["src/domain/**/*.ts", "src/sources/**/*.ts"],
  reporters: ["clear-text", "progress", "html"],
  thresholds: { high: 90, low: 80, break: 75 },
};
