#!/data/data/com.termux/files/usr/bin/bash
# build-termux.sh -- build rake on Termux (Moto G Power 2024, aarch64)
# Usage: bash build-termux.sh [clean]

set -e

BIN=zig-out/bin/rake

if [ "$1" = "clean" ]; then
  echo "[*] Cleaning build cache..."
  rm -rf .zig-cache zig-out
fi

echo "[*] Zig version: $(zig version)"
echo "[*] Building rake (ReleaseFast, aarch64-linux-musl)..."

zig build \
  -Doptimize=ReleaseFast \
  -Dtarget=aarch64-linux-musl

if [ -f "$BIN" ]; then
  echo "[+] Build successful: $BIN"
  echo "[*] Running self-tests..."
  $BIN
else
  echo "[-] Build failed: binary not found"
  exit 1
fi
