#!/usr/bin/env bash
# Builds a Release Achtung.app and installs it into ~/Applications, where Spotlight and
# Raycast find it. The version is the commit hash (with -dirty for uncommitted changes),
# the build number the commit count. Rebuilds are incremental, so an update takes
# seconds. A running Achtung is quit first and the new one started.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(git rev-parse --short HEAD)
[[ -z "$(git status --porcelain)" ]] || version+="-dirty"
build=$(git rev-list --count HEAD)
derived_data=.build/Release
installed="$HOME/Applications/Achtung.app"

xcodegen generate --quiet
xcodebuild build -quiet -skipPackagePluginValidation \
  -project Achtung.xcodeproj -scheme Achtung -configuration Release -destination platform=macOS \
  -derivedDataPath "$derived_data" MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build"

if pgrep -xq Achtung; then
  osascript -e 'tell application id "io.github.stibi.achtung" to quit'
  for _ in {1..50}; do pgrep -xq Achtung || break; sleep 0.1; done
fi
mkdir -p "$(dirname "$installed")"
rm -rf "$installed"
ditto "$derived_data/Build/Products/Release/Achtung.app" "$installed"
open "$installed"
echo "Installed Achtung $version ($build) to $installed"
