#!/bin/sh
# Builds core/ as static libraries for iOS, visionOS (device + simulator) and
# macOS (for SandKit's `swift test`), and packs them with core/include/sand.h
# into apple/SandKit/SandCore.xcframework. Not committed (about 6 MB a slice).
# Prints nothing unless it fails.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/core"
cargo=cargo
command -v cargo >/dev/null || cargo="$HOME/.cargo/bin/cargo"
targets="aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-visionos aarch64-apple-visionos-sim aarch64-apple-darwin"

out="$root/apple/SandKit/SandCore.xcframework"
stamp="$out/.built-from"
# Nothing to do if the core hasn't changed since the last pack.
hash=$(cat Cargo.toml Cargo.lock params.json include/sand.h src/*.rs | shasum | cut -c1-40)
[ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ] && exit 0

args=""
for t in $targets; do
  if ! log=$("$cargo" rustc --release --quiet --target "$t" --crate-type staticlib 2>&1); then
    printf '%s\n' "$log"
    exit 1
  fi
  args="$args -library target/$t/release/libsand_core.a -headers $root/apple/build/headers"
done

mkdir -p "$root/apple/build/headers"
cp include/sand.h "$root/apple/build/headers/"
cat > "$root/apple/build/headers/module.modulemap" <<'EOF'
module SandCore {
    header "sand.h"
    export *
}
EOF
rm -rf "$out"
# shellcheck disable=SC2086
if ! log=$(xcodebuild -create-xcframework $args -output "$out" 2>&1); then
  printf '%s\n' "$log"
  exit 1
fi
printf '%s\n' "$hash" > "$stamp"
