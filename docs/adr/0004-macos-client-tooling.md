# 0004: macOS client tooling and CI

- Status: accepted
- Date: 2026-11-07

## Context

[ADR 0001](0001-tech-stack.md) chose Swift 6, the latest macOS only, XcodeGen, and local
packages that build on Linux. [ADR 0003](0003-quality-enforcement.md) set up the quality
checks for the server, but for Swift it only names the compiler. The client needs the
same set of checks, behind the same gates.

Xcode 27.2 and macOS 27.2 are current. GitHub's `macos-latest` runner (macOS 26) ships
only Xcode 26, which can't build against the macOS 27 SDK. Since 2026-10-15 the
`xcode-27` runner image has been generally available
([changelog](https://github.blog/changelog/2026-10-16-xcode-27-runner-image-generally-available/);
the runner-images README still shows an outdated "preview" badge). It runs macOS 27.0.x,
and it ships Xcode 27.2 as a release candidate alongside a final 27.1, which is the
image's default.

## Decision

**Checks**, one per server tool where Swift has an equivalent, all run by
`macos/scripts/check.sh`:

| Server | Client | Notes |
|---|---|---|
| `tsc` strict | Swift 6 language mode, complete strict concurrency, warnings as errors | Set in `project.yml` and in each `Package.swift`. |
| Biome format | `swift format lint --strict` | Line length 100, 4-space indent (`.editorconfig`). |
| Biome lint | `swiftlint --strict` | Cyclomatic complexity 12, 60 lines per function, 300 lines per file, no force unwraps or force casts. |
| dependency-cruiser | SwiftPM package dependencies, a SwiftLint custom rule, the Linux CI job | The rule bans SwiftUI and AppKit in `AchtungDomain`. The Linux build also catches other Apple-only modules. |
| knip | Periphery | |
| Vitest | Swift Testing via `swift test` and `xcodebuild test` | |
| jscpd, Stryker | none yet | No mainstream Swift tool fits yet. Revisit once the client has real logic. |

The limits differ slightly from Biome's. SwiftLint measures cyclomatic complexity, not
cognitive complexity, and its file length counts blank lines.

**CI.** The `macos` job runs on `xcode-27` and selects `/Applications/Xcode_27.2.app`. Its
compiler matches local development, so warnings-as-errors fails the same way in both
places. On the image this path is currently the 27.2 release candidate, and the
symlink keeps working when the image updates it to the final release. The deployment target
is macOS 27.0, not 27.2, because the runner's OS is 27.0.x and the app tests have to
run there. "Latest macOS only" in ADR 0001 means the latest major version. A separate
`macos-domain-linux` job runs `swift test` for `AchtungDomain` in the official
`swift` container, pinned by digest.

**Tool installation.** CI installs XcodeGen, SwiftLint and Periphery with Homebrew,
which can't pin versions. `swift format` comes with Xcode.

**Gates.** The Claude Code hooks and the lefthook `macos` job run only on macOS. They
skip silently elsewhere.

## Consequences

- A new SwiftLint or Periphery release can add findings and turn CI red without a code
  change. Fix the findings, or pin the tool if that becomes a pattern.
- When Xcode 28 ships, move the runner label, the Xcode path and the deployment target
  together, in one change.
- Agents on Linux can't run the full client check. CI is their gate for `macos/`.
- There is no duplication or mutation check on the client yet.
