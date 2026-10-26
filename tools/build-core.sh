#!/bin/sh
# Builds core/ for wasm into src/sand_core.wasm, which is committed so the web
# app still runs from a plain static server. Prints nothing unless it fails.
set -e
cd "$(dirname "$0")/../core"
cargo=cargo
command -v cargo >/dev/null || cargo="$HOME/.cargo/bin/cargo"
if ! out=$("$cargo" build --release --quiet --target wasm32-unknown-unknown 2>&1); then
  printf '%s\n' "$out"
  exit 1
fi
cp target/wasm32-unknown-unknown/release/sand_core.wasm ../src/sand_core.wasm
chmod 644 ../src/sand_core.wasm
