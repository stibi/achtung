# 0003: How code quality is enforced

- Status: accepted
- Date: 2026-10-13

## Context

Most of the code is written by coding agents. Research and practitioner reports agree
on three things:
- Agent code degrades over repeated changes: it becomes more verbose, more duplicated,
  and piles complexity into a few functions.
- Prose instructions such as "write clean code" improve the starting point, but they
  don't slow the decay.
- Deterministic checks (types, linters, architecture tests) are the only reliable
  enforcement.

Sources: SlopCodeBench (arXiv 2603.24755), Anthropic's Claude Code best practices,
OpenAI's "Harness engineering", Codesai's architectural guardrails write-up.

## Decision

Every rule lives in the most deterministic place it can:

1. **Compiler:** a strict `tsconfig`, and Swift 6 strict concurrency checking.
2. **Linters and architecture tests:**
   - Biome: style, complexity and size limits, banned constructs.
   - dependency-cruiser: layers and boundaries. Every rule's message explains how to
     fix the violation.
   - knip: dead code.
   - jscpd: duplication.
3. **Gates that make sure the checks run:**
   - Claude Code hooks: a lint pass after each edit, and `pnpm check` must pass before
     the agent can stop.
   - lefthook git hooks: these apply to every agent and to humans.
   - GitHub Actions CI: the final gate.
   - A nightly mutation-testing run (Stryker) on the domain and source adapters.
4. **Prose** (`AGENTS.md`, `docs/`) only for what tools can't check: intent, domain
   rules, and the golden principles.
5. **A reviewer agent** for judgement calls (naming, whether an abstraction fits, scope
   creep), checked against `docs/golden-principles.md`.

When a prose rule turns into a check, delete the prose.

Biome thresholds: cognitive complexity 12, 60 lines per function, 300 lines per file.
jscpd fails on any clone of 8+ lines / 60+ tokens in `src/`. Stryker breaks below a 75%
mutation score.

### Version pins

These are held back on purpose, and Dependabot is told to ignore them:
- **TypeScript 6.x.** TypeScript 7 (the native compiler) has no stable API yet, and
  dependency-cruiser needs that API to analyze imports.
- **Vitest 4.x.** With Vitest 5, Stryker's vitest runner silently stops activating
  mutants, which reports every mutant as survived.

Revisit both when the tools add support. When you upgrade, prove the checks still
work: inject a known violation or mutant and confirm the tool catches it.

## Consequences

- Agents get fast, specific feedback in the loop instead of review comments after the
  fact.
- The thresholds are a starting point. Change them in a commit that explains why, never
  just to make a failing change pass.
- Disabling a rule inline (`biome-ignore`, `@ts-expect-error`) requires a comment
  explaining why. Reviewers treat each one as a smell.
- `pnpm check` runs on every agent stop and every commit, so it has to stay fast. Slow
  checks go into the nightly workflow.
