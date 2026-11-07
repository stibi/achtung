#!/usr/bin/env bash
# Every check for the macOS client: format, lint, package tests, app build and tests, dead
# code. Exits non-zero on the first failure. macOS only; needs xcodegen, swiftlint and
# periphery (brew install xcodegen swiftlint periphery).
set -euo pipefail

cd "$(dirname "$0")/.."
derived_data=.build/DerivedData

step() { printf '\n==> %s\n' "$*"; }

step xcodegen
xcodegen generate --quiet

step "swift format"
swift format lint --strict --recursive --parallel Achtung Packages/*/Package.swift \
  Packages/*/Sources Packages/*/Tests

step swiftlint
swiftlint lint --strict --quiet

for package in Packages/*/; do
  step "swift test ($package)"
  swift test --quiet --package-path "$package"
done

step "xcodebuild build test"
xcodebuild build test -quiet \
  -project Achtung.xcodeproj -scheme Achtung -destination platform=macOS \
  -derivedDataPath "$derived_data" COMPILER_INDEX_STORE_ENABLE=YES

step periphery
periphery scan --quiet --skip-build --index-store-path "$derived_data/Index.noindex/DataStore"
