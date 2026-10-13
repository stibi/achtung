# Golden principles

The taste of this codebase, for the judgement calls no linter can make. Reviewers, human
or agent, check changes against this list. Keep it short: a principle that doesn't
change decisions gets deleted.

1. **Solve the current problem.** No speculative abstractions, options or extension
   points. Introduce an interface once there are two real implementations, or one that
   crosses a layer boundary.
2. **Prefer deleting code to adding it.** A change that removes code while keeping the
   behavior is a good change.
3. **Parse at the boundary, trust inside.** Validate external data once, where it enters
   (HTTP, env, DB JSON, webhook payloads). Past that point, use the types and don't
   re-check them.
4. **Make illegal states unrepresentable.** Use discriminated unions over boolean flags
   and optional fields that only make sense together.
5. **Name things after the domain.** Use names like `Alert`, `Occurrence`, `Channel`,
   `acknowledge`. Avoid generic pattern names like `Manager`, `Helper`, `Util`,
   `Handler2` or `data`.
6. **Finish or don't start.** No TODOs, stubs, commented-out code or half-done
   features. If something is out of scope, leave it out and mention it in the PR.
7. **Follow the existing pattern.** Find the closest existing example and match its
   shape. If the pattern is wrong, change it everywhere in a separate change. Don't
   fork it.
8. **Errors are values at boundaries, exceptions for bugs.** Expected failures, such as
   an invalid payload or something not found, are returned as results. A `throw` means
   something is broken. Never swallow errors.
9. **Tests describe behavior.** Test through the public interface of a module, with real
   data. A test that has to change whenever internals are refactored is testing the
   wrong thing.
10. **UX is the product.** In the client, prefer calm, fast and obvious over clever.
    Every visual element must help answer "what is new, and what is still broken?"
