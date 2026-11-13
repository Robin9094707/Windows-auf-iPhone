#!/usr/bin/env bash
# Fetches StikJIT (MPL-2.0, github.com/StikDebug/StikJIT) – Swift sources plus the
# prebuilt idevice FFI static library – for the built-in JIT helper extension.
# Pinned to release 2.0.1.
set -euo pipefail
REV="b3e01a30ded4cd0b27cf1b6bd42f123bbdf49c3a"
DEST="$(cd "$(dirname "$0")/.." && pwd)/ios/Vendor/StikJIT"
if [ -f "$DEST/.rev" ] && [ "$(cat "$DEST/.rev")" = "$REV" ]; then
  echo "StikJIT $REV already present"; exit 0
fi
rm -rf "$DEST"; mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin https://github.com/StikDebug/StikJIT.git
git -C "$DEST" fetch -q --depth 1 origin "$REV"
git -C "$DEST" checkout -q FETCH_HEAD
rm -rf "$DEST/.git" "$DEST/idevice/tvos" "$DEST/Tests"
echo "$REV" > "$DEST/.rev"
ls -lh "$DEST/idevice"
