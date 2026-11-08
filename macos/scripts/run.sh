#!/usr/bin/env bash
# Builds a Debug Achtung.app from the working tree and starts it, for trying a change
# without installing it. It shares check.sh's build folder, so builds are incremental.
# The Debug app has the installed app's bundle id, and so its settings and read state; a
# running Achtung, installed or not, is quit first. Extra arguments go to the app, e.g.
# `-NSRequiresAquaSystemAppearance YES` for light mode.
set -euo pipefail

cd "$(dirname "$0")/.."
derived_data=.build/DerivedData
app="$derived_data/Build/Products/Debug/Achtung.app"

xcodegen generate --quiet
xcodebuild build -quiet -skipPackagePluginValidation \
  -project Achtung.xcodeproj -scheme Achtung -configuration Debug -destination platform=macOS \
  -derivedDataPath "$derived_data"

if pgrep -xq Achtung; then
  osascript -e 'tell application id "io.github.stibi.achtung" to quit'
  for _ in {1..50}; do pgrep -xq Achtung || break; sleep 0.1; done
fi
open -n "$app" --args "$@"
echo "Started $app"
