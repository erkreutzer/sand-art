#!/bin/sh
# Builds the iPhone app for the simulator: the core (tools/build-apple.sh),
# the Xcode project (XcodeGen, apple/project.yml), then the app. Prints only
# errors, then the path of the built .app.
#   tools/build-ios.sh [Debug|Release]
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-Debug}"
"$root/tools/build-apple.sh"
cd "$root/apple"
if ! log=$(xcodegen --quiet 2>&1); then printf '%s\n' "$log"; exit 1; fi
derived="$root/apple/build/DerivedData"
if ! log=$(xcodebuild -project SandArt.xcodeproj -scheme SandArt -configuration "$config" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" -quiet build 2>&1); then
  printf '%s\n' "$log" | grep -E 'error|failed' || printf '%s\n' "$log" | tail -30
  exit 1
fi
printf '%s\n' "$log" | grep -E 'error:' || true
echo "$derived/Build/Products/$config-iphonesimulator/SandArt.app"
