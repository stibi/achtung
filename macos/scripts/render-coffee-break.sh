#!/usr/bin/env bash
# Renders the krysa's coffee break (Live's "All caught up" scene) as looping GIFs into
# macos/Icon/coffee-break/, from the app's own scene and palette. macOS only.
set -euo pipefail
macos="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
swiftc -O -parse-as-library -o "$build/render-coffee-break" \
    "$macos/scripts/render-coffee-break.swift" \
    "$macos/Achtung/CoffeeBreakScene.swift" \
    "$macos/Achtung/CoffeeBreakPalette.swift"
"$build/render-coffee-break" "$macos/Icon/coffee-break"
